import Foundation
import SwiftUI

class SSHViewModel: ObservableObject {
    @Published var output = ""

    func appendOutput(_ message: String) {
        DispatchQueue.main.async {
            self.output += message + "\n"
        }
    }
}
