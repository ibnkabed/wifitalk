import SwiftUI

/// The built-in AI in the settings: ready with no key, and whether Apple's on-device model can answer on this phone.
struct BuiltInAISection: View {
    @ObservedObject private var hybrid = FirebaseHybrid.shared

    var body: some View {
        Section {
            Label(hybrid.isConfigured ? L("جاهز بلا مفتاح: Gemini عبر Firebase AI Logic") : L("غير متاح في هذه النسخة"),
                  systemImage: hybrid.isConfigured ? "checkmark.seal.fill" : "xmark.seal")
                .foregroundColor(hybrid.isConfigured ? .green : .secondary)
            LabeledContent("نموذج Apple على هذا الجوال", value: hybrid.onDeviceReady ? L("متاح") : L("غير متاح هنا"))
            if let engine = hybrid.lastEngine {
                LabeledContent("آخر طلب", value: engine == .onDevice ? L("على هذا الجوال") : L("في السحابة"))
            }
        } header: {
            Text("الذكاء الاصطناعي المدمج")
        } footer: {
            Text("زر الأوامر يفهم ما تقوله ثم يحوّله إلى أوامر ينفّذها الكمبيوتر، وزر «AI» بجانب النص الصوتي يصحّح ما أمليته قبل كتابته. الطلب القصير بلغة يدعمها نموذج Apple على الجهاز، كالإنجليزية، يُفهم على الجوال نفسه بخصوصية وبلا إنترنت. وما سواه، كالعربية والكتابة الطويلة، يفهمه Gemini في السحابة عبر Firebase AI Logic. والكمبيوتر ينفّذ فقط، ولا يشغّل أي ذكاء اصطناعي.")
        }
    }
}

/// What the app is, its source, and the copyright line.
struct AboutSection: View {
    var body: some View {
        Section("عن التطبيق") {
            Text("WiFiTalk يجعل الآيفون مساعدًا ذكيًا لكمبيوتر Windows، ولوحة مفاتيح ولوحة لمس وميكروفونًا وسماعة له، عبر الواي فاي.")
                .font(.callout)
            Link(destination: URL(string: "https://github.com/ibnkabed/wifitalk")!) {
                Label("الكود المصدري وبرنامج الكمبيوتر", systemImage: "chevron.left.forwardslash.chevron.right")
            }
            Text("Copyright (c) 2026 IbnKabed")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.layoutDirection, .leftToRight)
        }
    }
}
