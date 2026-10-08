//
//  Item.swift
//  LRMock
//
//  Created by sugartesalas on 2026-10-08.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
