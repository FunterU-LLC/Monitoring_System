import SwiftUI

extension Color {
    static func appOrange(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 255/255, green: 214/255, blue: 143/255)
            : Color(red: 255/255, green: 204/255, blue: 102/255)
    }
    
    static func appOrangeDark(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 255/255, green: 194/255, blue: 102/255)
            : Color(red: 230/255, green: 184/255, blue: 92/255)
    }
    
    static func appBrown(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 180/255, green: 140/255, blue: 110/255)
            : Color(red: 92/255, green: 64/255, blue: 51/255)
    }
    
    static func appOrangeLight(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 255/255, green: 234/255, blue: 183/255)
            : Color(red: 255/255, green: 224/255, blue: 153/255)
    }
    
    static let appOrange = Color(red: 255/255, green: 204/255, blue: 102/255)
    static let appOrangeDark = Color(red: 230/255, green: 184/255, blue: 92/255)
    static let appBrown = Color(red: 92/255, green: 64/255, blue: 51/255)
    static let appOrangeLight = Color(red: 255/255, green: 224/255, blue: 153/255)
}
