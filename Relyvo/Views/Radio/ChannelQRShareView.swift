import SwiftUI
import CoreImage.CIFilterBuiltins
import CryptoKit

struct ChannelQRShareView: View {
    let channelID: String
    @Environment(\.dismiss) private var dismiss
    
    @State private var qrCodeImage: UIImage?
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("Scan this code with another device to join the secure channel.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                
                if let qrCodeImage = qrCodeImage {
                    Image(uiImage: qrCodeImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 250, height: 250)
                        .padding()
                        .background(Color.white)
                        .cornerRadius(16)
                        .shadow(radius: 5)
                } else {
                    ProgressView()
                        .frame(width: 250, height: 250)
                }
                
                VStack(spacing: 8) {
                    Text(channelID)
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    if ChannelKeyStore.shared.hasKey(for: channelID) {
                        Label("End-to-End Encrypted", systemImage: "lock.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                    } else {
                        Label("Public Channel", systemImage: "globe")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }
                
                Spacer()
            }
            .padding()
            .navigationTitle("Share Channel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                generateQRCode()
            }
        }
    }
    
    private func generateQRCode() {
        var components = URLComponents()
        components.scheme = "relyvo"
        components.host = "channel"
        components.path = "/v1"
        
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "id", value: channelID)
        ]
        
        if let key = ChannelKeyStore.shared.key(for: channelID) {
            let keyData = key.withUnsafeBytes { Data($0) }
            let encodedKey = keyData.base64EncodedString()
            queryItems.append(URLQueryItem(name: "key", value: encodedKey))
        }
        
        components.queryItems = queryItems
        
        guard let urlString = components.url?.absoluteString else { return }
        
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(urlString.utf8)
        
        if let outputImage = filter.outputImage {
            // Scale up to avoid blurriness
            let transform = CGAffineTransform(scaleX: 10, y: 10)
            let scaledImage = outputImage.transformed(by: transform)
            if let cgimg = context.createCGImage(scaledImage, from: scaledImage.extent) {
                self.qrCodeImage = UIImage(cgImage: cgimg)
            }
        }
    }
}
