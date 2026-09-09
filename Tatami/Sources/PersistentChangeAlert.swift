// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import SwiftUI

extension View {
  func persistentChangeAlert<Action>(
    _ item: Binding<Store<AlertState<Action>, Action>?>,
    suppressible: Bool,
    suppress: Binding<Bool>,
  ) -> some View {
    background {
      if suppressible {
        Color.clear.alert(item)
          .dialogSuppressionToggle("Don't ask again", isSuppressed: suppress)
      } else {
        Color.clear.alert(item)
      }
    }
  }
}
