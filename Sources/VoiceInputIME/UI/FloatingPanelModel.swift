import Observation

@Observable
final class FloatingPanelModel {
    var audioLevel: Float = 0
    var isRefining: Bool = false
    var partialText: String? = nil
    var toastText: String? = nil
    var errorText: String? = nil
}
