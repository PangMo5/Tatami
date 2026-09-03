// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import IdentifiedCollections
import Testing
@testable import TatamiKit

struct WorkspaceChainTests {

  // MARK: Internal

  @Test
  func `every workspace resolves the same symmetric chain in stored order`() {
    let code = Workspace(name: "Code", displayHint: displayA)
    let chat = Workspace(name: "Chat")
    let chain = WorkspaceChain(
      name: "Coding",
      workspaceIDs: [code.id, chat.id],
    )
    let profile = Profile(
      name: "Default",
      workspaceChains: [chain],
      workspaces: [code, chat],
    )

    let validation = profile.validateWorkspaceChains()

    #expect(validation.isValid)
    #expect(validation.validChains == [chain])
    #expect(chain.workspaceIDs == [code.id, chat.id])
    #expect(profile.validWorkspaceChain(containing: code.id)?.id == chain.id)
    #expect(profile.validWorkspaceChain(containing: chat.id)?.id == chain.id)
  }

  @Test
  func `pinned and dynamic destinations do not create static chain conflicts`() {
    let firstPinned = Workspace(name: "First", displayHint: displayA)
    let secondPinned = Workspace(name: "Second", displayHint: displayA)
    let dynamic = Workspace(name: "Dynamic")
    let chain = WorkspaceChain(
      workspaceIDs: [firstPinned.id, secondPinned.id, dynamic.id]
    )
    let profile = Profile(
      name: "Default",
      workspaceChains: [chain],
      workspaces: [firstPinned, secondPinned, dynamic],
    )

    #expect(profile.validateWorkspaceChains().validChains == [chain])
  }

  @Test
  func `chain dynamic overrides pinned placement without changing ordinary dynamic placement`() {
    let pinned = Workspace(name: "Pinned", displayHint: displayA)
    let ordinaryDynamic = Workspace(name: "Dynamic")
    let chain = WorkspaceChain(
      workspaceIDs: [pinned.id, ordinaryDynamic.id],
      dynamicWorkspaceIDs: [pinned.id],
    )

    #expect(chain.isDynamicInChain(pinned))
    #expect(chain.isDynamicInChain(ordinaryDynamic))
  }

  @Test
  func `workspace in multiple chains invalidates every competing chain`() {
    let shared = Workspace(name: "Shared")
    let chat = Workspace(name: "Chat")
    let docs = Workspace(name: "Docs")
    let first = WorkspaceChain(workspaceIDs: [shared.id, chat.id])
    let second = WorkspaceChain(workspaceIDs: [shared.id, docs.id])
    let profile = Profile(
      name: "Default",
      workspaceChains: [first, second],
      workspaces: [shared, chat, docs],
    )

    let validation = profile.validateWorkspaceChains()

    #expect(validation.validChains.isEmpty)
    #expect(validation.issues.contains(.workspaceInMultipleChains(
      workspaceId: shared.id,
      chainIds: [first.id, second.id],
    )))
  }

  @Test
  func `invalid workspace references remain visible but cannot execute`() {
    let normal = Workspace(name: "Normal")
    let scratchpad = Workspace(name: "Scratch", kind: .scratchpad)
    let missingID = UUID()
    let chain = WorkspaceChain(
      workspaceIDs: [normal.id, scratchpad.id, missingID]
    )
    let profile = Profile(
      name: "Default",
      workspaceChains: [chain],
      workspaces: [normal, scratchpad],
    )

    let validation = profile.validateWorkspaceChains()

    #expect(profile.workspaceChains == [chain])
    #expect(validation.validChains.isEmpty)
    #expect(validation.issues.contains(.scratchpadWorkspace(
      chainId: chain.id,
      workspaceId: scratchpad.id,
    )))
    #expect(validation.issues.contains(.unknownWorkspace(
      chainId: chain.id,
      workspaceId: missingID,
    )))
  }

  @Test
  func `structural validation reports duplicate IDs short chains and repeated workspaces`() {
    let first = Workspace(name: "First")
    let second = Workspace(name: "Second")
    let third = Workspace(name: "Third")
    let duplicatedChainID = UUID()
    let duplicateIDFirst = WorkspaceChain(
      id: duplicatedChainID,
      workspaceIDs: [first.id, second.id],
    )
    let duplicateIDSecond = WorkspaceChain(
      id: duplicatedChainID,
      workspaceIDs: [third.id, UUID()],
    )
    let tooShort = WorkspaceChain(workspaceIDs: [third.id])
    let repeatedWorkspace = WorkspaceChain(workspaceIDs: [first.id, first.id])
    let profile = Profile(
      name: "Default",
      workspaceChains: [duplicateIDFirst, duplicateIDSecond, tooShort, repeatedWorkspace],
      workspaces: [first, second, third],
    )

    let validation = profile.validateWorkspaceChains()

    #expect(validation.validChains.isEmpty)
    #expect(validation.issues.contains(.duplicateChainID(chainId: duplicatedChainID)))
    #expect(validation.issues.contains(.tooFewWorkspaces(chainId: tooShort.id)))
    #expect(validation.issues.contains(.duplicateWorkspace(
      chainId: repeatedWorkspace.id,
      workspaceId: first.id,
    )))
    #expect(validation.issues.contains { issue in
      if case .unknownWorkspace(let chainId, _) = issue {
        chainId == duplicatedChainID
      } else {
        false
      }
    })
  }

  @Test
  func `validation rejects duplicate and nonmember dynamic workspace IDs`() {
    let first = Workspace(name: "First", displayHint: displayA)
    let second = Workspace(name: "Second")
    let nonmember = Workspace(name: "Nonmember")
    let chain = WorkspaceChain(
      workspaceIDs: [first.id, second.id],
      dynamicWorkspaceIDs: [first.id, first.id, nonmember.id],
    )
    let profile = Profile(
      name: "Default",
      workspaceChains: [chain],
      workspaces: [first, second, nonmember],
    )

    let validation = profile.validateWorkspaceChains()

    #expect(validation.validChains.isEmpty)
    #expect(validation.issues.contains(.duplicateDynamicWorkspace(
      chainId: chain.id,
      workspaceId: first.id,
    )))
    #expect(validation.issues.contains(.dynamicWorkspaceOutsideChain(
      chainId: chain.id,
      workspaceId: nonmember.id,
    )))
  }

  @Test
  func `normalizing chain dynamic IDs removes duplicates and nonmembers in chain order`() {
    let first = Workspace(name: "First")
    let second = Workspace(name: "Second")
    let third = Workspace(name: "Third")
    let nonmember = Workspace(name: "Nonmember")
    var chain = WorkspaceChain(
      workspaceIDs: [first.id, second.id, third.id],
      dynamicWorkspaceIDs: [third.id, nonmember.id, second.id, third.id],
    )

    chain.normalizeDynamicWorkspaceIDs()

    #expect(chain.dynamicWorkspaceIDs == [second.id, third.id])
    let profile = Profile(
      name: "Default",
      workspaceChains: [chain],
      workspaces: [first, second, third, nonmember],
    )
    #expect(profile.validateWorkspaceChains().isValid)
  }

  @Test
  func `workspace removal shrinks a chain and removes it below two workspaces`() throws {
    let first = Workspace(name: "First")
    let second = Workspace(name: "Second")
    let third = Workspace(name: "Third")
    let chain = WorkspaceChain(
      workspaceIDs: [first.id, second.id, third.id],
      dynamicWorkspaceIDs: [second.id, third.id],
    )
    var profile = Profile(
      name: "Default",
      workspaceChains: [chain],
      workspaces: [first, second, third],
    )

    profile.removeWorkspaceFromWorkspaceChains(second.id)
    let remaining = try #require(profile.workspaceChains.first)
    #expect(remaining.workspaceIDs == [first.id, third.id])
    #expect(remaining.dynamicWorkspaceIDs == [third.id])

    profile.removeWorkspaceFromWorkspaceChains(first.id)
    #expect(profile.workspaceChains.isEmpty)
  }

  @Test
  func `deleting or converting a workspace cleans chain membership`() throws {
    let first = Workspace(name: "First")
    let second = Workspace(name: "Second")
    let third = Workspace(name: "Third")
    let chain = WorkspaceChain(workspaceIDs: [first.id, second.id, third.id])
    let profile = Profile(
      name: "Default",
      workspaceChains: [chain],
      workspaces: [first, second, third],
    )
    var config = AppConfig(profiles: [profile])

    config.mutateWorkspace(second.id) { $0.kind = .scratchpad }
    var updatedProfile = try #require(config.profiles.first)
    #expect(updatedProfile.workspaceChains.first?.workspaceIDs == [first.id, third.id])

    config.removeWorkspace(first.id)
    updatedProfile = try #require(config.profiles.first)
    #expect(updatedProfile.workspaceChains.isEmpty)
    #expect(updatedProfile.workspaces[id: first.id] == nil)
  }

  @Test
  func `profile duplication remaps workspace and chain identities`() throws {
    let code = Workspace(name: "Code", displayHint: displayA)
    let chat = Workspace(name: "Chat")
    let sourceChain = WorkspaceChain(
      name: "Coding",
      workspaceIDs: [code.id, chat.id],
      dynamicWorkspaceIDs: [code.id],
    )
    let source = Profile(
      name: "Default",
      workspaceChains: [sourceChain],
      workspaces: [code, chat],
    )
    var config = AppConfig(profiles: [source])

    let duplication = config.duplicateProfile(source.id)
    let result = try #require(duplication)
    let clone = try #require(config.profiles.first { $0.id == result.profileId })
    let cloneChain = try #require(clone.workspaceChains.first)
    let clonedCodeID = try #require(result.workspaceIdMap[code.id])
    let clonedChatID = try #require(result.workspaceIdMap[chat.id])

    #expect(cloneChain.id != sourceChain.id)
    #expect(cloneChain.name == sourceChain.name)
    #expect(cloneChain.workspaceIDs == [clonedCodeID, clonedChatID])
    #expect(cloneChain.dynamicWorkspaceIDs == [clonedCodeID])
    #expect(sourceChain.dynamicWorkspaceIDs == [code.id])
    #expect(clone.validateWorkspaceChains().isValid)
  }

  @Test
  func `workspace duplication does not copy chain membership`() throws {
    let code = Workspace(name: "Code")
    let chat = Workspace(name: "Chat")
    let chain = WorkspaceChain(workspaceIDs: [code.id, chat.id])
    let profile = Profile(
      name: "Default",
      workspaceChains: [chain],
      workspaces: [code, chat],
    )
    var config = AppConfig(profiles: [profile])

    let duplication = config.duplicateWorkspace(code.id)
    let duplicateID = try #require(duplication)
    let updatedProfile = try #require(config.profiles.first)

    #expect(updatedProfile.workspaceChains == [chain])
    #expect(!updatedProfile.workspaceChains[0].workspaceIDs.contains(duplicateID))
  }

  // MARK: Private

  private let displayA = DisplayName(uuid: "display-a", name: "Studio Display")

}
