// Self-check for AttentionWatch's line parser. Run:
//   swiftc -parse-as-library tools/attention-check.swift Sources/Switch/AttentionWatch.swift -o /tmp/attention-check && /tmp/attention-check
import Foundation

@main
struct AttentionCheck {
    static func main() {
        var passed = 0
        func check(_ ok: Bool, _ what: String) {
            guard ok else { print("FAIL \(what)"); exit(1) }
            passed += 1
        }
        let on = #"Notification: kLSNotifyApplicationWantsAttentionChanged time=+1.49401s  dataRef={ "ChangeCount"=533, "LSASN"=ASN:0x0-0x51e81e3:, "LSPreviousValue"=false, "LSWantsAttention"=true } affectedASN="bounce" ASN:0x0-0x51e81e3:  context=0"#
        let off = #"Notification: kLSNotifyApplicationWantsAttentionChanged time=+1.00214s  dataRef={ "ChangeCount"=536, "LSASN"=ASN:0x0-0x51e81e3:, "LSPreviousValue"=true, "LSWantsAttention"=false } affectedASN="bounce" ASN:0x0-0x51e81e3:  context=0"#
        let other = #"Notification: kLSNotifyBecameFrontmost time=+1.37104s  dataRef={ "CFBundleIdentifier"="com.google.Chrome", "LSASN"=ASN:0x0-0x12012: }"#
        check(AttentionLine.parse(on) == AttentionLine(asn: "ASN:0x0-0x51e81e3:", wants: true), "attention on")
        check(AttentionLine.parse(off) == AttentionLine(asn: "ASN:0x0-0x51e81e3:", wants: false), "attention off")
        check(AttentionLine.parse(other) == nil, "other notifications ignored")
        // What `lsappinfo info -only pid <ASN>` really prints.
        check(AttentionLine.pid(fromInfo: "[ NULL ]  [ NULL ]  \n    bundleID=[ NULL ] \n    pid = 677 !cgsConnection !signalled type=[ NULL ]") == 677, "pid from lsappinfo info")
        check(AttentionLine.pid(fromInfo: #""pid"=35552"#) == 35552, "pid in notification form")
        check(AttentionLine.pid(fromInfo: "") == nil, "no pid")
        print("PASS \(passed) checks")
    }
}
