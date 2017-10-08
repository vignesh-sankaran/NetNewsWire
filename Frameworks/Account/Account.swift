//
//  Account.swift
//  DataModel
//
//  Created by Brent Simmons on 7/1/17.
//  Copyright © 2017 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import RSCore
import Data
import RSParser
import Database
import RSWeb

public extension Notification.Name {

	public static let AccountRefreshDidBegin = Notification.Name(rawValue: "AccountRefreshDidBegin")
	public static let AccountRefreshDidFinish = Notification.Name(rawValue: "AccountRefreshDidFinish")
	public static let AccountRefreshProgressDidChange = Notification.Name(rawValue: "AccountRefreshProgressDidChange")
}

public enum AccountType: Int {

	// Raw values should not change since they’re stored on disk.
	case onMyMac = 1
	case feedly = 16
	case feedbin = 17
	case feedWrangler = 18
	case newsBlur = 19
	// TODO: more
}

public final class Account: DisplayNameProvider, Hashable {

	public let accountID: String
	public let type: AccountType
	public var nameForDisplay = ""
	public let hashValue: Int
	let settingsFile: String
	let dataFolder: String
	let database: Database
	let delegate: AccountDelegate
	var topLevelObjects = [AnyObject]()
	var feedIDDictionary = [String: Feed]()
	var username: String?
	var saveTimer: Timer?

	private var dirty = false {
		didSet {
			if dirty {
				saveTimer?.rs_invalidateIfValid()
				saveTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { (timer) in
					self.saveToDiskIfNeeded()
					timer.rs_invalidateIfValid()
					self.saveTimer = nil
				}
			}
			else if !dirty {
				saveTimer?.rs_invalidateIfValid()
				saveTimer = nil
			}
		}
	}

	var refreshInProgress = false {
		didSet {
			if refreshInProgress != oldValue {
				if refreshInProgress {
					NotificationCenter.default.post(name: .AccountRefreshDidBegin, object: self)
				}
				else {
					NotificationCenter.default.post(name: .AccountRefreshDidFinish, object: self)
				}
			}
		}
	}

	var refreshProgress: DownloadProgress {
		get {
			return delegate.refreshProgress
		}
	}

	var hasAtLeastOneFeed: Bool {
		get {
			return !feedIDDictionary.isEmpty
		}
	}

	var supportsSubFolders: Bool {
		get {
			return delegate.supportsSubFolders
		}
	}

	init?(dataFolder: String, settingsFile: String, type: AccountType, accountID: String) {

		// TODO: support various syncing systems.
		precondition(type == .onMyMac)
		self.delegate = LocalAccountDelegate()

		self.accountID = accountID
		self.type = type
		self.settingsFile = settingsFile
		self.dataFolder = dataFolder
		self.hashValue = accountID.hashValue
		
		let databaseFilePath = (dataFolder as NSString).appendingPathComponent("DB.sqlite3")
		self.database = Database(databaseFilePath: databaseFilePath, accountID: accountID)

		NotificationCenter.default.addObserver(self, selector: #selector(downloadProgressDidChange(_:)), name: .DownloadProgressDidChange, object: nil)

		pullObjectsFromDisk()
	}
	
	// MARK: - API

	public func refreshAll() {

		delegate.refreshAll(for: self)
	}

	func update(_ feed: Feed, with parsedFeed: ParsedFeed, _ completion: RSVoidCompletionBlock) {

		completion()
	}

	public func markArticles(_ articles: Set<Article>, statusKey: String, flag: Bool) {
	
		database.mark(articles, statusKey: statusKey, flag: flag)
	}
	
	public func ensureFolder(with name: String) -> Folder? {
		
		return nil //TODO
	}

	public func canAddFeed(_ feed: Feed, to folder: Folder?) -> Bool {

		// If folder is nil, then it should go at the top level.
		// The same feed in multiple folders is allowed.
		// But the same feed can’t appear twice in the same folder
		// (or at the top level).

		return true // TODO
	}

	public func addFeed(_ feed: Feed, to folder: Folder?) -> Bool {

		// Return false if it couldn’t be added.
		// If it already existed in that folder, return true.

		var didAddFeed = false
		let uniquedFeed = existingFeed(with: feed.feedID) ?? feed
		
		if let folder = folder {
			didAddFeed = folder.addFeed(uniquedFeed)
		}
		else {
			if !topLevelObjectsContainsFeed(uniquedFeed) {
				topLevelObjects += [uniquedFeed]
			}
			didAddFeed = true
		}
		
		updateFeedIDDictionary()
		return didAddFeed // TODO
	}

	public func createFeed(with name: String?, editedName: String?, url: String) -> Feed? {
		
		// For syncing, this may need to be an async method with a callback,
		// since it will likely need to call the server.
		
		if let feed = existingFeed(withURL: url) {
			if let editedName = editedName {
				feed.editedName = editedName
			}
			return feed
		}
		
		let feed = Feed(accountID: accountID, url: url, feedID: url)
		feed.name = name
		feed.editedName = editedName
		return feed
	}
	
	public func canAddFolder(_ folder: Folder, to containingFolder: Folder?) -> Bool {

		return false // TODO
	}

	public func addFolder(_ folder: Folder, to containingFolder: Folder?) -> Bool {

		return false // TODO
	}

	public func importOPML(_ opmlDocument: RSOPMLDocument) {
	
		// TODO
	}

	// MARK: - Notifications

	@objc func downloadProgressDidChange(_ note: Notification) {

		guard let noteObject = note.object as? DownloadProgress, noteObject === refreshProgress else {
			return
		}

		refreshInProgress = refreshProgress.numberRemaining > 0
		NotificationCenter.default.post(name: .AccountRefreshProgressDidChange, object: self)
	}

	// MARK: - Equatable

	public class func ==(lhs: Account, rhs: Account) -> Bool {

		return lhs === rhs
	}
}


// MARK: - Disk

extension Account {
	
	private struct Key {
		static let children = "children"
	}

	func pullObjectsFromDisk() {

		let settingsFileURL = URL(fileURLWithPath: settingsFile)
		guard let d = NSDictionary(contentsOf: settingsFileURL) as? [String: Any] else {
			return
		}
		guard let childrenArray = d[Key.children] as? [[String: Any]] else {
			return
		}
		topLevelObjects = objects(with: childrenArray)
		updateFeedIDDictionary()
	}

	func objects(with diskObjects: [[String: Any]]) -> [AnyObject] {

		return diskObjects.flatMap { object(with: $0) }
	}

	func object(with diskObject: [String: Any]) -> AnyObject? {

		if Feed.isFeedDictionary(diskObject) {
			return Feed(accountID: accountID, dictionary: diskObject)
		}
		return Folder(account: self, dictionary: diskObject)
	}

	func saveToDiskIfNeeded() {

		if dirty {
			saveToDisk()
		}
	}

	private func diskDictionary() -> NSDictionary {

		let diskObjects = topLevelObjects.flatMap { (object) -> [String: Any]? in

			if let folder = object as? Folder {
				return folder.dictionary
			}
			else if let feed = object as? Feed {
				return feed.dictionary
			}
			return nil
		}

		var d = [String: Any]()
		d[Key.children] = diskObjects as NSArray
		return d as NSDictionary
	}

	func saveToDisk() {

		let d = diskDictionary()
		do {
			try RSPlist.write(d, filePath: settingsFile)
		}
		catch let error as NSError {
			NSApplication.shared.presentError(error)
		}

		dirty = false
	}
}

// MARK: - Private

private extension Account {

	func updateFeedIDDictionary() {

		var d = [String: Feed]()
		for feed in flattenedFeeds() {
			d[feed.feedID] = feed
		}
		feedIDDictionary = d
	}
	
	func topLevelObjectsContainsFeed(_ feed: Feed) -> Bool {
		
		return topLevelObjects.contains(where: { (object) -> Bool in
			if let oneFeed = object as? Feed {
				if oneFeed.feedID == feed.feedID {
					return true
				}
			}
			return false
		})
	}
}

// MARK: - OPMLRepresentable

extension Account: OPMLRepresentable {

	public func OPMLString(indentLevel: Int) -> String {

		var s = ""
		for oneObject in topLevelObjects {
			if let oneOPMLObject = oneObject as? OPMLRepresentable {
				s += oneOPMLObject.OPMLString(indentLevel: indentLevel + 1)
			}
		}
		return s
	}
}
