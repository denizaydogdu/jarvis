import Testing
@testable import JarvisCore

struct PathRulesTests {
    @Test func tildeAndCaseInsensitive() {
        #expect(PathRules.isUnder("/Users/u/dev/bim/a", prefix: "~/Dev/bim", home: "/Users/u"))
    }
    @Test func wholeComponentsOnly() {
        #expect(!PathRules.isUnder("/x/bimbo", prefix: "/x/bim", home: "/Users/u"))
    }
    @Test func equalPathsAreUnder() {
        #expect(PathRules.isUnder("/x/bim", prefix: "/x/bim", home: "/Users/u"))
    }
    @Test func trailingSlashOnPrefixIgnored() {
        #expect(PathRules.isUnder("/x/bim/a", prefix: "/x/bim/", home: "/Users/u"))
    }
    @Test func dotDotIsResolved() {
        #expect(!PathRules.isUnder("/x/bim/../other/a", prefix: "/x/bim", home: "/Users/u"))
    }
}
