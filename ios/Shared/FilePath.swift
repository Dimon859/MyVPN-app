//
//  FilePath.swift
//  SingBoxPacketTunnel
//
//  Created by GFWFighter on 7/25/1402 AP.
//

import Foundation

public enum FilePath {
    public static let packageName = {
        Bundle.main.infoDictionary?["BASE_BUNDLE_IDENTIFIER"] as? String ?? "unknown"
    }()
}

public extension FilePath {
    // MyVPN: группа, вписанная при сборке; если сертификат её не разрешает — берём группу из самого
    // сертификата (embedded.mobileprovision), так одна сборка работает с любым сертификатом.
    static let myDefaultGroup = "group.\(packageName)"

    static let groupName: String = {
        let fm = FileManager.default
        if fm.containerURL(forSecurityApplicationGroupIdentifier: myDefaultGroup) != nil { return myDefaultGroup }
        for g in myProvisionGroups() where fm.containerURL(forSecurityApplicationGroupIdentifier: g) != nil {
            return g
        }
        return myDefaultGroup
    }()

    /// Группы приложения из профиля, которым подписано приложение (у расширения — свой или профиль приложения).
    private static func myProvisionGroups() -> [String] {
        var urls: [URL] = []
        if let u = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision") { urls.append(u) }
        // расширение лежит в App.app/PlugIns/X.appex — профиль приложения двумя уровнями выше
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        urls.append(app.appendingPathComponent("embedded.mobileprovision"))
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let start = data.range(of: Data("<?xml".utf8)),
                  let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
            else { continue }
            let xml = data.subdata(in: start.lowerBound..<end.upperBound)
            guard let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any],
                  let ent = plist["Entitlements"] as? [String: Any],
                  let groups = ent["com.apple.security.application-groups"] as? [String], !groups.isEmpty
            else { continue }
            return groups.sorted()
        }
        return []
    }

    private static let defaultSharedDirectory: URL! = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: FilePath.groupName)

    static let sharedDirectory = defaultSharedDirectory!

    static let cacheDirectory = sharedDirectory
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Caches", isDirectory: true)

    static let workingDirectory = cacheDirectory.appendingPathComponent("Working", isDirectory: true)
}

public extension URL {
    var fileName: String {
        var path = relativePath
        if let index = path.lastIndex(of: "/") {
            path = String(path[path.index(index, offsetBy: 1)...])
        }
        return path
    }
}
