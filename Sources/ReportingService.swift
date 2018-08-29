//
//  RPServices.swift
//
//  Created by Stas Kirichok on 22/08/18.
//  Copyright © 2018 Windmill. All rights reserved.
//

import Foundation
import XCTest

enum ReportingServiceError: Error {
  case launchIdNotFound
  case testSuiteIdNotFound
}

class ReportingService {
  
  private let httpClient: HTTPClient
  private let configuration: AgentConfiguration
  
  private var launchID: String?
  private var testSuiteStatus = TestStatus.passed
  private var launchStatus = TestStatus.passed
  private var rootSuiteID: String?
  private var testSuiteID: String?
  private var testID = ""
  
  private let semaphore = DispatchSemaphore(value: 0)
  private let timeOutForRequestExpectation = 10.0
  
  init(configuration: AgentConfiguration) {
    self.configuration = configuration
    let baseURL = configuration.reportPortalURL.appendingPathComponent(configuration.projectName)
    httpClient = HTTPClient(baseURL: baseURL)
    httpClient.setPlugins([AuthorizationPlugin(token: configuration.portalToken)])
  }
  
  private func getStoredLaunchID(completion: @escaping (String?) -> Void) throws {
    let endPoint = GetCurrentLaunchEndPoint()
    try httpClient.callEndPoint(endPoint) { (result: LaunchListInfo) in
      guard let launch = result.content.first, let status = launch.status, status == "IN_PROGRESS" else {
        completion(nil)
        return
      }
      
      completion(launch.id)
    }
  }
  
  func startLaunch() throws {
    try getStoredLaunchID { (savedLaunchID: String?) in
      guard let savedLaunchID = savedLaunchID else {
        let endPoint = StartLaunchEndPoint(
          launchName: self.configuration.launchName,
          tags: self.configuration.tags,
          mode: self.configuration.launchMode
        )
        
        do {
          try self.httpClient.callEndPoint(endPoint) { (result: Launch) in
            self.launchID = result.id
            self.semaphore.signal()
          }
        } catch let error {
          print(error)
        }
        
        return
      }
      
      self.launchID = savedLaunchID
      self.semaphore.signal()
    }
    
    _ = semaphore.wait(timeout: .now() + timeOutForRequestExpectation)
  }
  
  func startRootSuite(_ suite: XCTestSuite) throws {
    guard let launchID = launchID else {
      throw ReportingServiceError.launchIdNotFound
    }
    
    let endPoint = StartItemEndPoint(itemName: suite.name, launchID: launchID, type: .suite)
    try httpClient.callEndPoint(endPoint) { (result: Item) in
      self.rootSuiteID = result.id
      self.semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + timeOutForRequestExpectation)
  }
  
  func startTestSuite(_ suite: XCTestSuite) throws {
    guard let launchID = launchID else {
      throw ReportingServiceError.launchIdNotFound
    }
    guard let rootSuiteID = rootSuiteID else {
      throw ReportingServiceError.launchIdNotFound
    }
    
    let endPoint = StartItemEndPoint(itemName: suite.name, parentID: rootSuiteID, launchID: launchID, type: .test)
    try httpClient.callEndPoint(endPoint) { (result: Item) in
      self.testSuiteID = result.id
      self.semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + timeOutForRequestExpectation)
  }
  
  func startTest(_ test: XCTestCase) throws {
    guard let launchID = launchID else {
      throw ReportingServiceError.launchIdNotFound
    }
    guard let testSuiteID = testSuiteID else {
      throw ReportingServiceError.testSuiteIdNotFound
    }
    let endPoint = StartItemEndPoint(itemName: test.name, parentID: testSuiteID, launchID: launchID, type: .step)
    
    try httpClient.callEndPoint(endPoint) { (result: Item) in
      self.testID = result.id
      self.semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + timeOutForRequestExpectation)
  }
  
  func reportError(message: String) throws {
    let endPoint = PostLogEndPoint(itemID: testID, level: "error", message: message)
    try httpClient.callEndPoint(endPoint) { (result: Item) in
      self.semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + timeOutForRequestExpectation)
  }
  
  func finishTest(_ test: XCTestCase) throws {
    let testStatus = test.testRun!.hasSucceeded ? TestStatus.passed : TestStatus.failed
    if testStatus == .failed {
      testSuiteStatus = .failed
      launchStatus = .failed
    }
    
    let endPoint = FinishItemEndPoint(itemID: testID, status: testStatus)
    
    try httpClient.callEndPoint(endPoint) { (result: Finish) in
      self.semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + timeOutForRequestExpectation)
  }
  
  func finishTestSuite() throws {
    guard let testSuiteID = testSuiteID else {
      throw ReportingServiceError.testSuiteIdNotFound
    }
    let endPoint = FinishItemEndPoint(itemID: testSuiteID, status: testSuiteStatus)
    try httpClient.callEndPoint(endPoint) { (result: Finish) in
      self.semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + timeOutForRequestExpectation)
  }
  
  func finishRootSuite() throws {
    guard let rootSuiteID = rootSuiteID else {
      throw ReportingServiceError.testSuiteIdNotFound
    }
    let endPoint = FinishItemEndPoint(itemID: rootSuiteID, status: launchStatus)
    try httpClient.callEndPoint(endPoint) { (result: Finish) in
      self.semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + timeOutForRequestExpectation)
  }
  
  func finishLaunch() throws {
    guard configuration.shouldFinishLaunch else {
      print("skip finish till next test bundle")
      return
    }
    guard let launchID = launchID else {
      throw ReportingServiceError.launchIdNotFound
    }
    let endPoint = FinishLaunchEndPoint(launchID: launchID, status: launchStatus)
    try httpClient.callEndPoint(endPoint) { (result: Finish) in
      self.semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + timeOutForRequestExpectation)
  }
}