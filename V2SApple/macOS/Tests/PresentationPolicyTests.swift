import Foundation
// Shared model's parser dependency is unrelated to these checks.
enum V2SXray {
 static func makeProfile(from: String) throws -> V2SProfile { throw TestError.unused }
 static func configuration(from: String) throws -> [String: Any] { throw TestError.unused }
}
enum TestError: Error { case unused }
@main struct PresentationPolicyTests {
 @MainActor static func main() throws {
  let now=Date(timeIntervalSince1970:100_000)
  precondition(V2SConnectionDuration.format(since:now,now:now)=="00:00:00")
  precondition(V2SConnectionDuration.format(since:now,now:now.addingTimeInterval(3661))=="01:01:01")
  precondition(V2SConnectionDuration.format(since:now,now:now.addingTimeInterval(90061))=="25:01:01")
  precondition(V2SConnectionDuration.format(since:now,now:now.addingTimeInterval(-10))=="00:00:00")
  var privateProfile=V2SProfile(name:"CA 1",protocolName:"vless",server:"vpn-ca.example.com",port:443,shareLink:"fixture")
  precondition(privateProfile.displayLocation()=="Canada")
  privateProfile.name="vless://user@vpn-ca.example.com:443"
  precondition(privateProfile.displayLocation()=="Location not provided")
  privateProfile.name="192.0.2.1"
  precondition(privateProfile.displayLocation()=="Location not provided")
  privateProfile.name="Personal location";privateProfile.countryCode="NL";privateProfile.city="Amsterdam"
  precondition(privateProfile.displayLocation()=="Netherlands · Amsterdam")
  privateProfile.city="vpn-ca.example.com";precondition(privateProfile.displayLocation()=="Netherlands")
  // Personal source countries and absent metadata never gate profile storage.
  var unrestricted=privateProfile;unrestricted.countryCode="IR"
  let userData=V2SData(profiles:[privateProfile,unrestricted])
  let roundTrip=try JSONDecoder().decode(V2SData.self,from:JSONEncoder().encode(userData))
  precondition(roundTrip.profiles.count==2)
  let legacy=V2SSettings();var encoded=try JSONSerialization.jsonObject(with:JSONEncoder().encode(legacy)) as! [String:Any]
  encoded.removeValue(forKey:"languageCode")
  let migrated=try JSONDecoder().decode(V2SSettings.self,from:JSONSerialization.data(withJSONObject:encoded));precondition(migrated.languageCode==nil)
  let resourceBundle=Bundle(path:ProcessInfo.processInfo.environment["V2S_LOCALIZATION_BUNDLE"]!)!
  precondition(V2SLocalization.text("Redeem offer code",language:"en",bundle:resourceBundle)=="Redeem offer code")
  precondition(V2SLocalization.text("Redeem offer code",language:"fa",bundle:resourceBundle) != "Redeem offer code")
  precondition(V2SLocalization.text("Redeem offer code",language:"fr",bundle:resourceBundle)=="Utiliser un code d’offre")
  let expectedLanguages = ["en", "fa", "ar", "zh-Hans", "ru", "es", "pt", "fr", "de"]
  precondition(V2SLocalization.languages.map(\.code) == expectedLanguages)
  let englishPath = resourceBundle.path(forResource: "en", ofType: "lproj")!
  let english = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: englishPath).appendingPathComponent("Localizable.strings")), format: nil) as! [String:String]
  for code in expectedLanguages {
   let path = resourceBundle.path(forResource: code, ofType: "lproj")!
   let values = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Localizable.strings")), format: nil) as! [String:String]
   precondition(Set(values.keys) == Set(english.keys), "Incomplete language: " + code)
   precondition(values.values.allSatisfy { !$0.isEmpty && !$0.contains("__V2SP") })
   if code != "en" {
    for key in ["Servers", "Settings", "Add server", "Restore Purchases", "Your privacy in V2S", "Remove Local Data"] {
     precondition(V2SLocalization.text(key, language:code,bundle:resourceBundle) != key, code + " missing " + key)
    }
    let dynamic = V2SLocalization.text("Refresh interval: 7 hours",language:code,bundle:resourceBundle)
    precondition(dynamic != "Refresh interval: 7 hours" && dynamic.contains("7"), code + " dynamic translation")
   }
   V2SLocalization.currentLanguage = code
   precondition(V2SLocalization.isRightToLeft == ["fa","ar"].contains(code))
  }
  V2SLocalization.currentLanguage = "en"
  print("PASS: nine compiled languages, all resource keys, dynamic messages, RTL, timer, unrestricted imports, endpoint redaction and migration")
 }
}
