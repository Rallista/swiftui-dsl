import Combine
import Foundation
import MapLibre
import MapLibreSwiftDSL

extension MLNCameraChangeReason: @retroactive CustomStringConvertible {
    private static let descriptions: [(Self, String)] = [
        (.programmatic, "programmatic"),
        (.resetNorth, "resetNorth"),
        (.gesturePan, "gesturePan"),
        (.gesturePinch, "gesturePinch"),
        (.gestureRotate, "gestureRotate"),
        (.gestureZoomIn, "gestureZoomIn"),
        (.gestureZoomOut, "gestureZoomOut"),
        (.gestureOneFingerZoom, "gestureOneFingerZoom"),
        (.gestureTilt, "gestureTilt"),
        (.transitionCancelled, "transitionCancelled"),
    ]

    public var description: String {
        var names = Self.descriptions.filter { contains($0.0) }.map(\.1)
        if names.isEmpty {
            names = ["none"]
        }
        return names.joined(separator: ",")
    }
}

@MainActor
public class MapViewCoordinator<T: MapViewHostViewController>: NSObject, @preconcurrency
MLNMapViewDelegate {
    // This must be weak, the UIViewRepresentable owns the MLNMapView.
    weak var mapView: MLNMapView?
    var parent: MapView<T>

    // Storage of variables as they were previously; these are snapshot
    // every update cycle so we can avoid unnecessary updates
    private var snapshotUserLayers: [StyleLayerDefinition] = []
    private var snapshotCamera: MapViewCamera?
    private var snapshotStyleSource: MapStyleSource?

    /// An asyncronous task that applies the camera update and awaits the map to reach idle state.
    var cameraUpdateTask: Task<Void, Never>?

    /// This continuation is closed with the MapView becomes idle at the end of a camera update.
    /// A canceled camera update (think a gesture midway through another camera update)
    /// should cancel and reset this.
    var cameraUpdateContinuation: CheckedContinuation<Void, Never>?

    var onStyleLoaded: ((MLNStyle) -> Void)?
    var onUserTrackingModeChange: ((MLNUserTrackingMode, Bool) -> Void)?
    var onMapIdle: ((MapViewProxy) -> Void)?
    var onMapDidFinishRendering: ((MapViewProxy, Bool) -> Void)?
    var onMapTileError: (() -> Void)?
    var onGesture: (MLNMapView, UIGestureRecognizer) -> Void
    var onViewProxyChanged: (MapViewProxy) -> Void
    var proxyUpdateMode: ProxyUpdateMode
    var managedGestureRecognizers: [UIGestureRecognizer] = []
    var isUsingDefaultLocationManager = true

    /// Debounces rapid-fire tile error callbacks so the consumer receives one
    /// notification per burst rather than one per individual failing tile.
    private var tileErrorDebounceTask: Task<Void, Never>?

    init(
        parent: MapView<T>,
        onGesture: @escaping (MLNMapView, UIGestureRecognizer) -> Void,
        onViewProxyChanged: @escaping (MapViewProxy) -> Void,
        proxyUpdateMode: ProxyUpdateMode
    ) {
        self.parent = parent
        self.onGesture = onGesture
        self.onViewProxyChanged = onViewProxyChanged
        self.proxyUpdateMode = proxyUpdateMode
    }

    /// Seeds the snapshot with the style already applied during map view construction,
    /// so the first SwiftUI update does not redundantly reload the same style URL.
    func markStyleSourceApplied(_ source: MapStyleSource) {
        snapshotStyleSource = source
    }

    // MARK: Core UIView Functionality

    @objc func captureGesture(_ sender: UIGestureRecognizer) {
        guard let mapView else {
            return
        }

        onGesture(mapView, sender)
    }

    /// This function sets up a callback on the registered `MapViewGestureManager`.
    /// Each time the callback emits a modified list of gestures, they are synced to the map view.
    func registerGestureListener() {
        parent.gestureManager.onGestureChange = { [weak self] gestures in
            guard let self, let mapView else { return }
            syncGestures(on: mapView, gestures: gestures)
        }
    }

    // MARK: - Coordinator API - Styles + Layers

    @MainActor func updateStyleSource(_ source: MapStyleSource, mapView: MLNMapView) {
        switch (source, snapshotStyleSource) {
        case let (.url(newURL), .url(oldURL)):
            if newURL != oldURL {
                mapView.styleURL = newURL
            }
        case let (.url(newURL), .none):
            mapView.styleURL = newURL
        }

        snapshotStyleSource = source
    }

    /// Makes the style match the layers of ``parent``, and keeps the layers and sources that did not change.
    @MainActor func updateLayers(mapView: MLNMapView) {
        let previousLayers = snapshotUserLayers
        let layers = parent.userLayers
        snapshotUserLayers = layers

        // If the style is not loaded, the style didFinishLoading callback adds the layers.
        guard let style = mapView.style else {
            return
        }

        let previousSources = managedSources(of: previousLayers)
        let sources = managedSources(of: layers)
        let replacedSources = updateSources(sources, from: previousSources, in: style)

        // Each layer after the first change is added again, so that the layers keep their order.
        let unchangedLayerCount = zip(previousLayers, layers).prefix { previous, layer in
            guard isEqual(previous, layer), style.layer(withIdentifier: layer.identifier) != nil else {
                return false
            }
            guard let sourceID = (layer as? SourceBoundStyleLayerDefinition)?.source.identifier else {
                return true
            }
            return !replacedSources.contains(sourceID)
        }.count

        for layer in previousLayers.dropFirst(unchangedLayerCount) {
            if let oldLayer = style.layer(withIdentifier: layer.identifier) {
                style.removeLayer(oldLayer)
            }
        }

        // Remove a source only after the layers that use it.
        let removedSources = Set(previousSources.keys).subtracting(sources.keys).union(replacedSources)
        for sourceID in removedSources {
            if let source = style.source(withIdentifier: sourceID) {
                style.removeSource(source)
            }
        }

        addLayers(Array(layers.dropFirst(unchangedLayerCount)), to: style)
    }

    /// Returns the sources that layers specify through the DSL, by identifier.
    ///
    /// This leaves out each ``MLNSource``, because the app manages it. For a shared identifier, the first
    /// layer's source is used, because the style gets that one.
    private func managedSources(of layers: [StyleLayerDefinition]) -> [String: Source] {
        var sources: [String: Source] = [:]
        for case let layer as SourceBoundStyleLayerDefinition in layers {
            if case let .source(source) = layer.source, sources[source.identifier] == nil {
                sources[source.identifier] = source
            }
        }
        return sources
    }

    /// Updates the sources that stay in the style.
    ///
    /// - Returns: The identifiers of the sources that cannot change in place.
    private func updateSources(
        _ sources: [String: Source],
        from previousSources: [String: Source],
        in style: MLNStyle
    ) -> Set<String> {
        var replacedSources = Set<String>()
        for (identifier, source) in sources {
            if let previous = previousSources[identifier],
               let styleSource = style.source(withIdentifier: identifier),
               !source.update(styleSource, from: previous)
            {
                replacedSources.insert(identifier)
            }
        }
        return replacedSources
    }

    private func isEqual(_ previous: StyleLayerDefinition, _ layer: StyleLayerDefinition) -> Bool {
        func isEqual<Layer: Equatable>(_ previous: Layer) -> Bool {
            previous == layer as? Layer
        }

        guard let previous = previous as? any Equatable else {
            return false
        }
        return isEqual(previous)
    }

    func addLayers(_ layers: [StyleLayerDefinition], to mglStyle: MLNStyle) {
        let userLayerIdentifiers = Set(parent.userLayers.map(\.identifier))
        let firstSymbolLayer = mglStyle.layers.first { layer in
            layer is MLNSymbolStyleLayer && !userLayerIdentifiers.contains(layer.identifier)
        }

        for layerSpec in layers {
            // DISCUSS: What preventions should we try to put in place against the user accidentally adding the same layer twice?
            let newLayer = layerSpec.makeStyleLayer(style: mglStyle).makeMLNStyleLayer()

            // Unconditionally transfer the common properties
            newLayer.isVisible = layerSpec.isVisible

            if let minZoom = layerSpec.minimumZoomLevel {
                newLayer.minimumZoomLevel = minZoom
            }

            if let maxZoom = layerSpec.maximumZoomLevel {
                newLayer.maximumZoomLevel = maxZoom
            }

            switch layerSpec.insertionPosition {
            case let .above(.layer(layerId: id)):
                if let layer = mglStyle.layer(withIdentifier: id) {
                    mglStyle.insertLayer(newLayer, above: layer)
                } else {
                    NSLog("Failed to find layer with ID \(id). Adding layer on top.")
                    mglStyle.addLayer(newLayer)
                }
            case .above(.all):
                mglStyle.addLayer(newLayer)
            case let .below(.layer(layerId: id)):
                if let layer = mglStyle.layer(withIdentifier: id) {
                    mglStyle.insertLayer(newLayer, below: layer)
                } else {
                    NSLog("Failed to find layer with ID \(id). Adding layer on top.")
                    mglStyle.addLayer(newLayer)
                }
            case .below(.all):
                mglStyle.insertLayer(newLayer, at: 0)
            case .below(.symbols):
                if let firstSymbolLayer {
                    mglStyle.insertLayer(newLayer, below: firstSymbolLayer)
                } else {
                    mglStyle.addLayer(newLayer)
                }
            }
        }
    }

    // MARK: - Camera

    /// Apply a camera change based on the current @State of the camera.
    ///
    /// - Parameters:
    ///   - mapView: The MapView that the state is being updated for.
    ///   - camera: The new camera state
    ///   - animated: Whether the camera change should be animated. Defaults to `true`.
    @MainActor func applyCameraChangeFromStateUpdate(
        _ mapView: MLNMapViewRepresentable,
        camera: MapViewCamera,
        animated: Bool = true
    ) {
        guard camera != snapshotCamera else {
            // No action - camera has not changed.
            return
        }

        snapshotCamera = camera

        // Cancel any existing camera update completion task.
        cameraUpdateTask?.cancel()

        cameraUpdateTask = Task { @MainActor in
            await withCheckedContinuation { continuation in
                // Clean up the continuation if it was already set.
                cameraUpdateContinuation?.resume()
                cameraUpdateContinuation = nil

                // Store the continuation to be resumed in mapViewDidBecomeIdle
                cameraUpdateContinuation = continuation

                // Apply the camera settings based on camera.state
                switch camera.state {
                case let .centered(
                    onCoordinate: coordinate,
                    zoom: zoom,
                    pitch: pitch,
                    pitchRange: pitchRange,
                    direction: direction
                ):
                    mapView.userTrackingMode = .none

                    if mapView.frame.size == .zero {
                        // On init, the mapView's frame is not set up yet, so manipulation via camera is broken,
                        // so let's do something else instead.
                        mapView.setCenter(coordinate,
                                          zoomLevel: zoom,
                                          direction: direction,
                                          animated: animated)

                        // this is a workaround for no camera - minimum and maximum will be reset below, but this
                        // adjusts it.
                        mapView.minimumPitch = pitch
                        mapView.maximumPitch = pitch

                        // Keep the configured pitch range after the initialization workaround.
                        mapView.minimumPitch = pitchRange.rangeValue.lowerBound
                        mapView.maximumPitch = pitchRange.rangeValue.upperBound
                    } else {
                        // Apply pitch bounds before setting camera pitch so transitions from fixed-pitch
                        // tracking modes can animate to a lower pitch without being clamped.
                        mapView.minimumPitch = pitchRange.rangeValue.lowerBound
                        mapView.maximumPitch = pitchRange.rangeValue.upperBound

                        let camera = mapView.camera
                        camera.centerCoordinate = coordinate
                        camera.heading = direction
                        camera.pitch = pitch

                        let altitude = MLNAltitudeForZoomLevel(zoom, pitch, coordinate.latitude, mapView.frame.size)
                        camera.altitude = altitude
                        mapView.setCamera(camera, animated: animated)
                    }
                case let .trackingUserLocation(zoom: zoom, pitch: pitch, pitchRange: pitchRange, direction: direction):
                    if mapView.frame.size == .zero {
                        // On init, the mapView's frame is not set up yet, so manipulation via camera is broken,
                        // so let's do something else instead.
                        // Needs to be non-animated or else it messes up following

                        mapView.userTrackingMode = .follow

                        mapView.zoomLevel = zoom
                        mapView.direction = direction

                        mapView.minimumPitch = pitch
                        mapView.maximumPitch = pitch
                        mapView.minimumPitch = pitchRange.rangeValue.lowerBound
                        mapView.maximumPitch = pitchRange.rangeValue.upperBound
                    } else {
                        mapView.setUserTrackingMode(.follow, animated: animated) {
                            guard mapView.userTrackingMode == .follow else {
                                // Exit early if the user tracking mode is no longer set to follow
                                return
                            }

                            mapView.zoomLevel = zoom
                            mapView.direction = direction

                            mapView.minimumPitch = pitch
                            mapView.maximumPitch = pitch
                            mapView.minimumPitch = pitchRange.rangeValue.lowerBound
                            mapView.maximumPitch = pitchRange.rangeValue.upperBound
                        }
                    }
                case let .trackingUserLocationWithHeading(zoom: zoom, pitch: pitch, pitchRange: pitchRange):
                    if mapView.frame.size == .zero {
                        // On init, the mapView's frame is not set up yet, so manipulation via camera is broken,
                        // so let's do something else instead.
                        // Needs to be non-animated or else it messes up following

                        mapView.userTrackingMode = .followWithHeading

                        mapView.zoomLevel = zoom

                        mapView.minimumPitch = pitch
                        mapView.maximumPitch = pitch
                        mapView.minimumPitch = pitchRange.rangeValue.lowerBound
                        mapView.maximumPitch = pitchRange.rangeValue.upperBound
                    } else {
                        mapView.setUserTrackingMode(.followWithHeading, animated: animated) {
                            guard mapView.userTrackingMode == .followWithHeading else {
                                // Exit early if the user tracking mode is no longer set to followWithHeading
                                return
                            }

                            mapView.zoomLevel = zoom

                            mapView.minimumPitch = pitch
                            mapView.maximumPitch = pitch
                            mapView.minimumPitch = pitchRange.rangeValue.lowerBound
                            mapView.maximumPitch = pitchRange.rangeValue.upperBound
                        }
                    }
                case let .trackingUserLocationWithCourse(zoom: zoom, pitch: pitch, pitchRange: pitchRange):
                    if mapView.frame.size == .zero {
                        mapView.userTrackingMode = .followWithCourse
                        // On init, the mapView's frame is not set up yet, so manipulation via camera is broken,
                        // so let's do something else instead.
                        // Needs to be non-animated or else it messes up following

                        mapView.zoomLevel = zoom

                        mapView.minimumPitch = pitch
                        mapView.maximumPitch = pitch
                        mapView.minimumPitch = pitchRange.rangeValue.lowerBound
                        mapView.maximumPitch = pitchRange.rangeValue.upperBound
                    } else {
                        mapView.setUserTrackingMode(.followWithCourse, animated: animated) {
                            guard mapView.userTrackingMode == .followWithCourse else {
                                // Exit early if the user tracking mode is no longer set to followWithCourse
                                return
                            }

                            mapView.zoomLevel = zoom

                            mapView.minimumPitch = pitch
                            mapView.maximumPitch = pitch
                            mapView.minimumPitch = pitchRange.rangeValue.lowerBound
                            mapView.maximumPitch = pitchRange.rangeValue.upperBound
                        }
                    }
                case let .rect(boundingBox, padding):
                    mapView.minimumPitch = 0
                    mapView.maximumPitch = 0
                    mapView.direction = 0

                    mapView.setVisibleCoordinateBounds(boundingBox,
                                                       edgePadding: padding,
                                                       animated: animated,
                                                       completionHandler: nil)
                case let .showcase(shapeCollection, padding):
                    mapView.userTrackingMode = .none
                    mapView.minimumPitch = 0
                    mapView.maximumPitch = 0
                    mapView.direction = 0

                    let camera = mapView.cameraThatFitsShape(
                        shapeCollection,
                        direction: 0,
                        edgePadding: padding
                    )
                    mapView.setCamera(camera, animated: animated)
                }
            }
        }
    }

    /// Apply a gesture based camera change. This behavior will only be triggered on the first gesture and will
    /// only be completed when the mapView becomes idle.
    ///
    /// - Parameters:
    ///   - mapView: The MapView that is being manipulated by a gesture.
    ///   - reason: The reason for the camera change.
    @MainActor func applyCameraChangeFromGesture(_ mapView: MLNMapViewRepresentable, reason: CameraChangeReason) {
        guard cameraUpdateTask == nil else {
            // Gestures emit many updates, so we only want to launch the first one and rely on idle to close the event.
            return
        }

        cameraUpdateTask = Task { @MainActor in
            await withCheckedContinuation { continuation in
                // Store the continuation to be resumed in mapViewDidBecomeIdle
                cameraUpdateContinuation = continuation

                let pitchRange: CameraPitchRange = if mapView.minimumPitch == 0 && mapView.maximumPitch > 59.9 {
                    .free
                } else if mapView.minimumPitch == mapView.maximumPitch {
                    .fixed(mapView.minimumPitch)
                } else {
                    .freeWithinRange(minimum: mapView.minimumPitch, maximum: mapView.maximumPitch)
                }

                parent.camera = .center(
                    mapView.centerCoordinate,
                    zoom: mapView.zoomLevel,
                    pitch: mapView.camera.pitch,
                    pitchRange: pitchRange,
                    direction: mapView.direction,
                    reason: reason
                )
            }
        }
    }

    // MARK: - MLNMapViewDelegate

    @MainActor
    public func mapView(_ mapView: MLNMapView, didFinishLoading mglStyle: MLNStyle) {
        addLayers(parent.userLayers, to: mglStyle)
        let viewProxy = MapViewProxy(
            mapView: mapView,
            lastReasonForChange: nil
        )
        onViewProxyChanged(viewProxy)
        onStyleLoaded?(mglStyle)
    }

    /// Called by MapLibre for every tile lifecycle event.
    ///
    /// Only ``MLNTileOperation/error`` is acted on, it indicates a tile
    /// request failed, typically due to no internet or a poor connection.
    ///
    /// The callback is debounced to 3ms, a burst of simultaneously
    /// failing tiles within the window produces a single notification
    /// rather than many.
    @MainActor
    public func mapView(
        _: MLNMapView,
        tileDidTriggerAction operation: MLNTileOperation,
        x _: Int,
        y _: Int,
        z _: Int,
        wrap _: Int,
        overscaledZ _: Int,
        sourceID _: String
    ) {
        guard operation == .error else { return }
        tileErrorDebounceTask?.cancel()
        tileErrorDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            onMapTileError?()
        }
    }

    /// The MapView's region has changed with a specific reason.
    @MainActor
    public func mapView(
        _ mapView: MLNMapView, regionDidChangeWith reason: MLNCameraChangeReason, animated _: Bool
    ) {
        // TODO: We could put this in regionIsChangingWith if we calculate significant change/debounce.
        // regionIsChangingWith is not called for the final update, so we need to call updateViewProxy
        // in both modes here.
        updateViewProxy(mapView: mapView, reason: reason)

        guard let changeReason = CameraChangeReason(reason) else {
            // Invalid state - we cannot process this camera change.
            return
        }

        switch changeReason {
        case .gesturePan, .gesturePinch, .gestureRotate,
             .gestureZoomIn, .gestureZoomOut, .gestureOneFingerZoom,
             .gestureTilt:
            applyCameraChangeFromGesture(mapView, reason: changeReason)
        default:
            break
        }
    }

    @MainActor
    public func mapViewDidBecomeIdle(_ mapView: MLNMapView) {
        cameraUpdateContinuation?.resume()
        cameraUpdateContinuation = nil
        cameraUpdateTask = nil

        let viewProxy = MapViewProxy(
            mapView: mapView,
            lastReasonForChange: nil
        )
        onMapIdle?(viewProxy)
    }

    @MainActor
    public func mapViewDidFinishRenderingMap(_ mapView: MLNMapView, fullyRendered: Bool) {
        let viewProxy = MapViewProxy(
            mapView: mapView,
            lastReasonForChange: nil
        )
        onMapDidFinishRendering?(viewProxy, fullyRendered)
    }

    @MainActor
    public func mapView(styleForDefaultUserLocationAnnotationView _: MLNMapView) -> MLNUserLocationAnnotationViewStyle {
        if let value = parent.annotationStyle?.value {
            value
        } else {
            MLNUserLocationAnnotationViewStyle()
        }
    }

    @MainActor
    public func mapView(_ mapView: MLNMapView, regionIsChangingWith reason: MLNCameraChangeReason) {
        if proxyUpdateMode == .realtime {
            updateViewProxy(mapView: mapView, reason: reason)
        }
    }

    @MainActor
    public func mapView(_: MLNMapView, didChange mode: MLNUserTrackingMode, animated: Bool) {
        onUserTrackingModeChange?(mode, animated)
    }

    // MARK: MapViewProxy

    @MainActor private func updateViewProxy(mapView: MLNMapView, reason: MLNCameraChangeReason) {
        // Calculate the Raw "ViewProxy"
        let calculatedViewProxy = MapViewProxy(
            mapView: mapView,
            lastReasonForChange: CameraChangeReason(reason)
        )

        onViewProxyChanged(calculatedViewProxy)
    }
}

public enum ProxyUpdateMode {
    /// Causes the `MapViewProxy`to be updated in realtime, including during map view scrolling and animations.
    /// This will cause multiple updates per seconds. Use only if you really need to run code in realtime while users
    /// are changing the shown region.
    case realtime
    /// Default. Causes `MapViewProxy` to be only be updated when a map view scroll or animation completes.
    case onFinish
}
