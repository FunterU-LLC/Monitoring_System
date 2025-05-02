//AppColorManager.swift
import SwiftUI

private struct HSB: Codable {
    let h: Double
    let s: Double
    let b: Double
}

final class AppColorManager {
    static let shared = AppColorManager()
    private let storeKey = "AppColorHSBCache"

    private var cache: [String: HSB]

    private init() {
        if let data = UserDefaults.standard.data(forKey: storeKey),
           let dict = try? JSONDecoder().decode([String: HSB].self, from: data) {
            cache = dict
        } else {
            cache = [:]
        }
    }

    func color(for appName: String) -> Color {
        if let tuple = cache[appName] {
            return Color(hue: tuple.h, saturation: tuple.s, brightness: tuple.b)
        } else {
            let color = generateColor(from: appName)
            cache[appName] = HSB(h: color.hue, s: color.sat, b: color.bri)
            save()
            return Color(hue: color.hue, saturation: color.sat, brightness: color.bri)
        }
    }

    private func generateColor(from str: String)
        -> (hue: Double, sat: Double, bri: Double) {

        let hueVal = str.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 360 }
        let hue = Double(hueVal) / 360.0         // 0.0 – 1.0

        let len = max(1, min(str.count, 20))
        let sat = 0.55 + (Double(len % 3) * 0.1)
        let bri = 0.80

        return (hue, sat, bri)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }
}
