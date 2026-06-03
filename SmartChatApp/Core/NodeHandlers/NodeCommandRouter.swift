import Foundation
import OpenClawKit
import UIKit

public final class NodeCommandRouter: @unchecked Sendable {
    private var handlers: [String: CommandHandler] = [:]
    private let locationService = LocationService()
    private let deviceService = DeviceService()
    private let locationMode: OpenClawLocationMode

    init() {
        self.locationMode = ConfigurationManager.shared.locationMode
        registerHandlers()
    }

    private func registerHandlers() {
        // Location commands
        register("location.get", handler: locationGetHandler)

        // Device commands
        register("device.status", handler: deviceStatusHandler)
        register("device.info", handler: deviceInfoHandler)

        // Canvas commands (stubs)
        register("canvas.present", handler: stubHandler("canvas.present"))
        register("canvas.hide", handler: stubHandler("canvas.hide"))
        register("canvas.navigate", handler: stubHandler("canvas.navigate"))
        register("canvas.eval", handler: stubHandler("canvas.eval"))
        register("canvas.snapshot", handler: stubHandler("canvas.snapshot"))

        // Canvas A2UI commands (stubs)
        register("canvas.a2ui.push", handler: stubHandler("canvas.a2ui.push"))
        register("canvas.a2ui.pushJSONL", handler: stubHandler("canvas.a2ui.pushJSONL"))
        register("canvas.a2ui.reset", handler: stubHandler("canvas.a2ui.reset"))

        // Screen commands (stubs)
        register("screen.record", handler: stubHandler("screen.record"))

        // System commands (stubs)
        register("system.notify", handler: stubHandler("system.notify"))

        // Chat commands (stubs)
        register("chat.push", handler: stubHandler("chat.push"))

        // Talk commands (stubs)
        register("talk.ptt.start", handler: stubHandler("talk.ptt.start"))
        register("talk.ptt.stop", handler: stubHandler("talk.ptt.stop"))
        register("talk.ptt.cancel", handler: stubHandler("talk.ptt.cancel"))
        register("talk.ptt.once", handler: stubHandler("talk.ptt.once"))

        // Camera commands (stubs)
        register("camera.list", handler: stubHandler("camera.list"))
        register("camera.snap", handler: stubHandler("camera.snap"))
        register("camera.clip", handler: stubHandler("camera.clip"))

        // Photos commands (stubs)
        register("photos.latest", handler: stubHandler("photos.latest"))

        // Contacts commands (stubs)
        register("contacts.search", handler: stubHandler("contacts.search"))
        register("contacts.add", handler: stubHandler("contacts.add"))

        // Calendar commands (stubs)
        register("calendar.events", handler: stubHandler("calendar.events"))
        register("calendar.add", handler: stubHandler("calendar.add"))

        // Reminders commands (stubs)
        register("reminders.list", handler: stubHandler("reminders.list"))
        register("reminders.add", handler: stubHandler("reminders.add"))
    }

    private func register(_ command: String, handler: @escaping CommandHandler) {
        handlers[command] = handler
    }

    private func stubHandler(_ command: String) -> CommandHandler {
        return { request in
            return BridgeInvokeResponse(
                type: "response",
                id: request.id,
                ok: true,
                payloadJSON: nil,
                error: nil
            )
        }
    }

    public func handle(_ request: BridgeInvokeRequest) async -> BridgeInvokeResponse {
        guard let handler = handlers[request.command] else {
            return BridgeInvokeResponse(
                type: "response",
                id: request.id,
                ok: false,
                payloadJSON: nil,
                error: OpenClawNodeError(
                    code: .unavailable,
                    message: "Unknown command: \(request.command)"
                )
            )
        }

        do {
            return try await handler(request)
        } catch let error as NodeHandlerError {
            return BridgeInvokeResponse(
                type: "response",
                id: request.id,
                ok: false,
                payloadJSON: nil,
                error: error.toOpenClawError()
            )
        } catch {
            return BridgeInvokeResponse(
                type: "response",
                id: request.id,
                ok: false,
                payloadJSON: nil,
                error: OpenClawNodeError(
                    code: .unavailable,
                    message: error.localizedDescription
                )
            )
        }
    }

    // MARK: - Location Handler

    private var locationGetHandler: CommandHandler {
        return { [self] request in
            let mode = self.locationMode

            // Check if location is disabled
            if mode == .off {
                throw NodeHandlerError.unavailable(reason: "LOCATION_DISABLED: enable Location in Settings")
            }

            // Parse params
            let params = Self.parseParams(OpenClawLocationGetParams.self, from: request.paramsJSON) ?? OpenClawLocationGetParams()

            // Get location (LocationService will handle permission request)
            do {
                let location = try await locationService.currentLocation(
                    params: params,
                    desiredAccuracy: params.desiredAccuracy ?? .balanced,
                    maxAgeMs: params.maxAgeMs,
                    timeoutMs: params.timeoutMs
                )

                let isPrecise = locationService.accuracyAuthorization == .fullAccuracy

                // Format timestamp as ISO8601 string
                let timestampFormatter = ISO8601DateFormatter()
                let timestampString = timestampFormatter.string(from: location.timestamp)

                let payload = OpenClawLocationPayload(
                    lat: location.coordinate.latitude,
                    lon: location.coordinate.longitude,
                    accuracyMeters: location.horizontalAccuracy,
                    altitudeMeters: location.altitude,
                    speedMps: location.speed >= 0 ? location.speed : nil,
                    headingDeg: location.course >= 0 ? location.course : nil,
                    timestamp: timestampString,
                    isPrecise: isPrecise
                )

                let encoder = JSONEncoder()
                let payloadData = try encoder.encode(payload)
                let payloadJSON = String(data: payloadData, encoding: .utf8)

                return BridgeInvokeResponse(
                    type: "response",
                    id: request.id,
                    ok: true,
                    payloadJSON: payloadJSON,
                    error: nil
                )
            } catch let error as LocationService.LocationError {
                switch error {
                case .permissionDenied:
                    throw NodeHandlerError.permissionRequired(feature: "LOCATION_PERMISSION_REQUIRED: grant Location permission")
                case .timeout:
                    throw NodeHandlerError.unavailable(reason: "LOCATION_TIMEOUT: request timed out")
                case .unavailable:
                    throw NodeHandlerError.unavailable(reason: "LOCATION_UNAVAILABLE: \(error.localizedDescription)")
                case .disabled:
                    throw NodeHandlerError.unavailable(reason: "LOCATION_DISABLED")
                }
            } catch {
                throw NodeHandlerError.unavailable(reason: "Failed to get location: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Device Handlers

    private var deviceStatusHandler: CommandHandler {
        return { [self] request in
            let status = deviceService.status()

            let encoder = JSONEncoder()
            let payloadData = try encoder.encode(status)
            let payloadJSON = String(data: payloadData, encoding: .utf8)

            return BridgeInvokeResponse(
                type: "response",
                id: request.id,
                ok: true,
                payloadJSON: payloadJSON,
                error: nil
            )
        }
    }

    private var deviceInfoHandler: CommandHandler {
        return { [self] request in
            let info = deviceService.info()

            let encoder = JSONEncoder()
            let payloadData = try encoder.encode(info)
            let payloadJSON = String(data: payloadData, encoding: .utf8)

            return BridgeInvokeResponse(
                type: "response",
                id: request.id,
                ok: true,
                payloadJSON: payloadJSON,
                error: nil
            )
        }
    }

    // MARK: - Helpers

    private static func parseParams<T: Decodable>(_ type: T.Type, from json: String?) -> T? {
        guard let json = json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}