import Dependencies
import Foundation
import GRDB
import OSLog
import SQLiteData

/// Factory for the Tatami app database. Call once at app launch via
/// `prepareDependencies { $0.defaultDatabase = try TatamiDatabase.make() }`.
///
/// In `live` context, opens `~/Library/Application Support/Tatami/tatami.sqlite`.
/// In `preview` / `test` contexts, SQLiteData provisions a fresh in-memory db
/// per invocation.
public enum TatamiDatabase {
  public static func make() throws -> any DatabaseWriter {
    @Dependency(\.context) var context
    var configuration = Configuration()
    #if DEBUG
      configuration.prepareDatabase { db in
        db.trace(options: .profile) { event in
          if context == .preview {
            print("[Tatami.DB] \(event.expandedDescription)")
          } else {
            logger.debug("\(event.expandedDescription)")
          }
        }
      }
    #endif

    let database = try defaultDatabase(configuration: configuration)
    logger.info("Opened Tatami DB at \(database.path)")

    var migrator = DatabaseMigrator()
    #if DEBUG
      migrator.eraseDatabaseOnSchemaChange = true
    #endif
    migrator.registerMigration("0001 Initial schema") { db in
      try #sql(
        """
        CREATE TABLE "profiles"(
          "id" TEXT NOT NULL PRIMARY KEY,
          "name" TEXT NOT NULL,
          "shortcut" TEXT,
          "sortOrder" INTEGER NOT NULL DEFAULT 0
        ) STRICT
        """
      )
      .execute(db)

      try #sql(
        """
        CREATE TABLE "workspaces"(
          "id" TEXT NOT NULL PRIMARY KEY,
          "profileId" TEXT NOT NULL REFERENCES "profiles"("id") ON DELETE CASCADE,
          "name" TEXT NOT NULL,
          "displayHint" TEXT,
          "activateShortcut" TEXT,
          "assignAppShortcut" TEXT,
          "symbolIconName" TEXT,
          "openAppsOnActivation" INTEGER NOT NULL DEFAULT 0,
          "appToFocusBundleId" TEXT,
          "sortOrder" INTEGER NOT NULL DEFAULT 0
        ) STRICT
        """
      )
      .execute(db)

      try #sql(
        """
        CREATE TABLE "app_assignments"(
          "id" TEXT NOT NULL PRIMARY KEY,
          "workspaceId" TEXT NOT NULL REFERENCES "workspaces"("id") ON DELETE CASCADE,
          "bundleIdentifier" TEXT NOT NULL,
          "name" TEXT NOT NULL,
          "iconPath" TEXT,
          "autoOpen" INTEGER NOT NULL DEFAULT 0,
          "sortOrder" INTEGER NOT NULL DEFAULT 0,
          UNIQUE("workspaceId", "bundleIdentifier")
        ) STRICT
        """
      )
      .execute(db)

      try #sql(
        """
        CREATE TABLE "floating_apps"(
          "bundleIdentifier" TEXT NOT NULL PRIMARY KEY,
          "name" TEXT NOT NULL,
          "iconPath" TEXT
        ) STRICT
        """
      )
      .execute(db)

      try #sql(
        """
        CREATE INDEX "workspaces_profileId_idx" ON "workspaces"("profileId")
        """
      )
      .execute(db)

      try #sql(
        """
        CREATE INDEX "app_assignments_workspaceId_idx"
          ON "app_assignments"("workspaceId")
        """
      )
      .execute(db)
    }

    try migrator.migrate(database)
    return database
  }
}

private let logger = Logger(subsystem: "dev.PangMo5.Tatami", category: "Database")
