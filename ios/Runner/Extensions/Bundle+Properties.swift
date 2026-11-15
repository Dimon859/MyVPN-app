//
//  Bundle+Properties.swift
//  Runner
//
//  Created by Hiddify on 12/26/23.
//

import Foundation

extension Bundle {
    var serviceIdentifier: String {
        (infoDictionary?["SERVICE_IDENTIFIER"] as? String)!
    }
    
    var baseBundleIdentifier: String {
        (infoDictionary?["BASE_BUNDLE_IDENTIFIER"] as? String)!
    }

    /// MyVPN: настоящий ID VPN-расширения из PlugIns — подписчик мог переименовать его под свой сертификат.
    var myTunnelBundleIdentifier: String {
        if let plugins = builtInPlugInsURL,
           let items = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) {
            let ids = items.filter { $0.pathExtension == "appex" }.compactMap { Bundle(url: $0)?.bundleIdentifier }
            if let id = ids.first(where: { $0.hasSuffix(".HiddifyPacketTunnel") }) ?? ids.first { return id }
        }
        return baseBundleIdentifier + ".HiddifyPacketTunnel"
    }
}
