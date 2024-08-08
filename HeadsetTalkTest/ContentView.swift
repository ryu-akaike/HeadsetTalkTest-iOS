//
//  ContentView.swift
//  HeadsetTalkTest
//
//  Created by 赤池龍 on 2024/08/05.
//

import SwiftUI

struct ContentView: View {
    @State var echoback = Echoback()
    var body: some View {
        VStack {
            Text("Cannot stop the echoback using a headset button")
            Button {
                if(echoback.isRecording){
                    echoback.stop()
                }else{
                    echoback.start()
                }
            } label: {
                Text("Press this or a headset button to enable / disable the echoback")
            }
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
