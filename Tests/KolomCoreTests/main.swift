import Foundation
import KolomCore

// The core checks, in the order they always ran. Each file holds one area.
try layoutChecks()
try recoveryChecks()
try invariantChecks()
try presenceChecks()
try displayChecks()
try updateChecks()
try performanceChecks()
try diskMapChecks()
try windowReturnChecks()
try idleSessionChecks()
try spaceStripChecks()
