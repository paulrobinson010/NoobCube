import CoreText
import SwiftUI
import UIKit

/// The app's lettering: Baloo 2, the face the NoobCube wordmark is drawn in
/// and the one the website sets its text in.
///
/// It is one file with a weight axis rather than a family of files, which iOS
/// will not pick a weight from on its own — ask for it by name and you get 400
/// whatever you asked for. So the weight is dialled into the axis by hand.
///
/// If the font is missing for any reason the rounded system face stands in. It
/// is the closest thing iOS has and nothing about the layout depends on which
/// of the two is in use.
enum BrandFont {
    static let familyName = "Baloo 2"

    /// 'wght', the only axis this face has. It runs from 400 to 800.
    private static let weightAxis = 0x77676874

    static var isAvailable: Bool { UIFont.familyNames.contains(familyName) }

    /// Where a SwiftUI weight sits on the axis.
    ///
    /// Baloo 2 starts at 400 and its 400 is already fairly solid, so the light
    /// end of the scale has nowhere to go and the heavy end is spread out.
    static func axisValue(for weight: Font.Weight) -> CGFloat {
        switch weight {
        case .ultraLight, .thin, .light: return 400
        case .regular:  return 430
        case .medium:   return 500
        case .semibold: return 580
        case .bold:     return 660
        case .heavy:    return 740
        case .black:    return 800
        default:        return 500
        }
    }

    static func uiFont(size: CGFloat, weight: Font.Weight) -> UIFont {
        guard isAvailable else { return fallback(size: size, weight: weight) }
        let variation = UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
        let descriptor = UIFontDescriptor(fontAttributes: [
            .family: familyName,
            variation: [weightAxis: axisValue(for: weight)],
        ])
        return UIFont(descriptor: descriptor, size: size)
    }

    private static func fallback(size: CGFloat, weight: Font.Weight) -> UIFont {
        let system = UIFont.systemFont(ofSize: size, weight: systemWeight(for: weight))
        guard let rounded = system.fontDescriptor.withDesign(.rounded) else { return system }
        return UIFont(descriptor: rounded, size: size)
    }

    private static func systemWeight(for weight: Font.Weight) -> UIFont.Weight {
        switch weight {
        case .ultraLight: return .ultraLight
        case .thin:       return .thin
        case .light:      return .light
        case .regular:    return .regular
        case .medium:     return .medium
        case .semibold:   return .semibold
        case .bold:       return .bold
        case .heavy:      return .heavy
        case .black:      return .black
        default:          return .medium
        }
    }
}

extension Font {
    /// NoobCube's own lettering. Use this instead of `.system`, so that the
    /// app, the wordmark and the website are all written the same way.
    static func brand(size: CGFloat, weight: Font.Weight = .bold) -> Font {
        Font(BrandFont.uiFont(size: size, weight: weight))
    }
}
