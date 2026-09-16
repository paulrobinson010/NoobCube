import SwiftUI

extension SolveStage.Kind {

    /// The colour this step is shown in.
    ///
    /// The same eight colours the website gives the same eight steps, so a
    /// child who has seen the list on the website recognises it in the app.
    /// Generated from `Design/tokens.json` — run `Tools/sync_design.py`.
    var tint: Color {
        // BEGIN generated from Design/tokens.json
        switch self {
        case .hold: return Theme.attention
        case .daisy:        return CubeColour.white.swiftUIColor
        case .whiteCross:   return CubeColour.white.swiftUIColor
        case .whiteCorners: return CubeColour.blue.swiftUIColor
        case .middleRow:    return CubeColour.blue.swiftUIColor
        case .yellowCross:  return CubeColour.yellow.swiftUIColor
        case .yellowFace:   return CubeColour.yellow.swiftUIColor
        case .lastCorners:  return CubeColour.orange.swiftUIColor
        case .lastEdges:    return CubeColour.green.swiftUIColor
        }
        // END generated
    }
}
