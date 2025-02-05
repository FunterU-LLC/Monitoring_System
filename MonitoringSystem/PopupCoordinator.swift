import Observation   // Combine 不要。Observation マクロのみで変更通知が届く

@Observable
class PopupCoordinator {
    // 旧 @Published を削除し、通常プロパティに
    var showTaskStartPopup: Bool = false
    var showWorkInProgress:  Bool = false
    var showFinishPopup:     Bool = false
}

