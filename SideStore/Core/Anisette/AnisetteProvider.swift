//
//  AnisetteProvider.swift
//  SideStore
//
//  Created by Magesh K on 8/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import SideSign

enum AnisetteProvider {
    /// Fork (login fix, version 2): Apple now rejects sign-in and 2FA requests that identify as Windows/iTunes
    /// (error -80046 after the verification code). Sign-in therefore starts from a Mac anisette server, and
    /// uses the client info that server reports instead of the app's default identity.
    private static let preferredHosts = ["mac-ani.jkcoxson.com", "new.ani.sidestore.io"]

    /// Anisette state provisioned under another server's identity is not valid for a Mac server, so the stored
    /// ADI blob is thrown away once.
    private static let adiMigrationKey = "MacAnisette.purgeAdi.v1"

    static func fetch(handler: AnisetteServerHandler? = nil) async throws -> ALTAnisetteData {
        // Fork: on-device anisette is generated with libraries that identify as another platform, and Apple
        // now answers its sign-in request with HTTP 503. Always use a Mac anisette server instead.
        if UserDefaults.standard.useOnDeviceAnisette {
            debugLog("[AnisetteProvider] On-device anisette switched off (Mac anisette server fix)")
            UserDefaults.standard.useOnDeviceAnisette = false
        }
        debugLog("[AnisetteProvider] Fetching anisette via remote server...")
        return try await fetchRemote(handler: handler)
    }

    /// Fork: GET <server>/v3/client_info, the identity this anisette server provisions (nil if unreachable).
    private static func fetchServerClientInfo(from serverURL: URL) async -> (clientInfo: String, userAgent: String)? {
        guard var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/v3/get_headers") {
            path = String(path.dropLast("/v3/get_headers".count))
        }
        components.path = path + "/v3/client_info"
        components.query = nil
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let clientInfo = json["client_info"] as? String, !clientInfo.isEmpty
            else {
                debugLog("[AnisetteProvider] /v3/client_info from \(serverURL.absoluteString) was not usable")
                return nil
            }
            let userAgent = (json["user_agent"] as? String) ?? ""
            debugLog("[AnisetteProvider] Server \(serverURL.absoluteString) client_info: \(clientInfo), ua: \(userAgent)")
            return (clientInfo, userAgent)
        } catch {
            debugLog("[AnisetteProvider] /v3/client_info failed for \(serverURL.absoluteString): \(error)")
            return nil
        }
    }

    private static func fetchRemote(handler: AnisetteServerHandler? = nil) async throws -> ALTAnisetteData {
        let serverUrlStrings = await AnisetteServersManager.shared.getActiveServerURLs()
        var servers = serverUrlStrings.compactMap { URL(string: $0) }
        guard !servers.isEmpty else {
            throw AnisetteError.noServersConfigured
        }

        // Fork: Mac servers first, in the order of preferredHosts; the rest keep their order after them.
        let macServers = preferredHosts.compactMap { host in servers.first(where: { $0.host == host }) }
        if !macServers.isEmpty {
            servers = macServers + servers.filter { !macServers.contains($0) }
        }

        let lastServer = UserDefaults.standard.menuAnisetteURL
        var startIndex = servers.firstIndex(where: { $0.absoluteString == lastServer }) ?? 0
        let lastHost = URL(string: lastServer)?.host ?? ""
        if !macServers.isEmpty && !preferredHosts.contains(lastHost) {
            startIndex = 0
            debugLog("[AnisetteProvider] Starting from \(servers[0].absoluteString) instead of the saved server \(lastServer)")
        }

        // Fork: one-time purge of the stored ADI blob (provisioned under another server's identity).
        if !UserDefaults.standard.bool(forKey: adiMigrationKey) {
            AnisetteConfigManager.shared.anisetteAdiBlob = nil
            UserDefaults.standard.set(true, forKey: adiMigrationKey)
            debugLog("[AnisetteProvider] Purged the stored ADI blob for Mac anisette re-provisioning")
        }

        let provider = SideSign.AnisetteDataManager.shared
        let existingBlob = AnisetteConfigManager.shared.anisetteAdiBlob.flatMap { Data(base64Encoded: $0) }
        let identifier = await AnisetteConfigManager.shared.resolveDeviceIdentifier()
        var headers = await AnisetteConfigManager.shared.makeRequestHeaders()

        // Fork: use the identity the chosen server reports, not the app's default or a user override.
        let serverIdentity = await fetchServerClientInfo(from: servers[startIndex])
        if let serverIdentity {
            headers.clientInfo = serverIdentity.clientInfo
            if !serverIdentity.userAgent.isEmpty {
                headers.userAgent = serverIdentity.userAgent
            }
        }

        let (anisetteData, newAdiBlob) = try await provider.fetchAnisetteDataWithFailover(
            servers: UserDefaults.standard.disableAnisetteRotation ? [servers[startIndex]] : servers,
            startIndex: startIndex,
            identifier: identifier,
            existingAdiBlob: existingBlob,
            headers: headers,
            onError: { error in
                if let anisetteError = error as? SideSign.AnisetteError,
                   case .outdatedV1Server(let serverURL, _) = anisetteError {
                    if UserDefaults.standard.defaultServerURL == serverURL.absoluteString {
                        return true
                    }
                    if let handler = handler {
                        let shouldContinue = try await handler.warnOutdatedAnisetteServer()
                        if shouldContinue {
                            UserDefaults.standard.defaultServerURL = serverURL.absoluteString
                        }
                        return shouldContinue
                    }
                }
                return false
            },
            onSuccess: { successfulServer in
                UserDefaults.standard.menuAnisetteURL = successfulServer.absoluteString
                debugLog("[AnisetteProvider] Successfully fetched Anisette data from \(successfulServer.absoluteString)")
            }
        )

        if let freshBlob = newAdiBlob {
            AnisetteConfigManager.shared.anisetteAdiBlob = freshBlob.base64EncodedString()
        }

        // Fork: sign-in and 2FA requests read the identity from the anisette data.
        var data = anisetteData
        if let serverIdentity {
            data.clientInfo = serverIdentity.clientInfo
            if !serverIdentity.userAgent.isEmpty {
                data.userAgent = serverIdentity.userAgent
            }
        }
        return data
    }
}
