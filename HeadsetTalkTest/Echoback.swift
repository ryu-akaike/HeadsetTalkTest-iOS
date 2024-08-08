//
//  Echoback.swift
//  HeadsetTalkTest
//
//  Created by 赤池龍 on 2024/08/05.
//

import Foundation
import AVFoundation
import MediaPlayer

class Echoback{
    struct RefConData{
        var audioUnit: AudioUnit
        var soundBuf = SoundDataQueue()
    }
    var audioComponent : AudioComponent
    var audioSession: AVAudioSession
    var refData: RefConData
    var pRefData: UnsafeMutableRawPointer
    var dummyPlayer: AVAudioPlayer
    init(){
        // Instantiate AudioUnit
        var desc = AudioComponentDescription()
        desc.componentType = kAudioUnitType_Output
        desc.componentSubType = kAudioUnitSubType_RemoteIO
        desc.componentManufacturer = kAudioUnitManufacturer_Apple
        desc.componentFlags = 0
        desc.componentFlagsMask = 0
        guard let ac = AudioComponentFindNext(nil, &desc) else {
            print("AudioComponentFindNext failed.")
            abort()
        }
        audioComponent = ac
        
        audioSession = AVAudioSession.sharedInstance()
        do{
            try audioSession.setCategory(.playback, mode: .default)
            try audioSession.setActive(true)
        }catch{
            print(error.localizedDescription)
            abort()
        }
        
        var au : AudioUnit?
        var status = AudioComponentInstanceNew(audioComponent, &au)
        if(status != noErr){
            print("AudioComponentInstanceNew failed.")
            abort()
        }
        guard let au2 = au else {
            print("AudioComponentInstanceNew failed.")
            abort()
        }
        refData = RefConData(audioUnit: au2)
        pRefData = withUnsafeMutablePointer(to: &refData,{
            UnsafeMutableRawPointer($0)
        })
        
        // Enable AudioUnit I/O
        var enable : UInt32 = 1
        status = AudioUnitSetProperty(refData.audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size))
        if(status != noErr){
            print("AudioUnitSetProperty(kAudioOutputUnitProperty_EnableIO) failed.")
            abort()
        }
        status = AudioUnitSetProperty(refData.audioUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enable, UInt32(MemoryLayout<UInt32>.size))
        if(status != noErr){
            print("AudioUnitSetProperty(kAudioOutputUnitProperty_EnableIO) failed.")
            abort()
        }
        
        // Set audio stream format
        var streamFormat = AudioStreamBasicDescription()
        streamFormat.mSampleRate = 8000
        streamFormat.mFormatID = kAudioFormatLinearPCM
        streamFormat.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked
        streamFormat.mBitsPerChannel = 16
        streamFormat.mChannelsPerFrame = 1
        streamFormat.mBytesPerFrame = streamFormat.mChannelsPerFrame * streamFormat.mBitsPerChannel / 8
        streamFormat.mFramesPerPacket = 1
        streamFormat.mBytesPerPacket = streamFormat.mBytesPerFrame * streamFormat.mFramesPerPacket
        
        status = AudioUnitSetProperty(refData.audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &streamFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        if(status != noErr){
            print("AudioUnitSetProperty(kAudioUnitProperty_StreamFormat) failed.")
            abort()
        }
        status = AudioUnitSetProperty(refData.audioUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &streamFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        if(status != noErr){
            print("AudioUnitSetProperty(kAudioUnitProperty_StreamFormat) failed.")
            abort()
        }
        
        // Set audio input callback
        var inputCallback = AURenderCallbackStruct(inputProc: { inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData in
            let refData_ = inRefCon.assumingMemoryBound(to: Echoback.RefConData.self).pointee
            
            let dataSize = UInt32( 1 * inNumberFrames * UInt32( MemoryLayout<Int16>.size ) )
            let audioBuffer = AudioBuffer.init(mNumberChannels: 1, mDataByteSize: dataSize, mData: nil)
            var audioBufferList = AudioBufferList.init(mNumberBuffers: 1, mBuffers: audioBuffer)
            let status = AudioUnitRender(refData_.audioUnit, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, &audioBufferList)
            if(status != noErr){
                return status
            }
            let data = Data(bytes:audioBufferList.mBuffers.mData!, count: Int(audioBufferList.mBuffers.mDataByteSize))
            
            refData_.soundBuf.enqueue(data)
            return noErr
        }, inputProcRefCon: pRefData)
        status = AudioUnitSetProperty(refData.audioUnit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1, &inputCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size(ofValue: inputCallback)))
        if(status != noErr){
            print("AudioUnitSetProperty(kAudioOutputUnitProperty_SetInputCallback) failed.")
            abort()
        }
        
        // Set audio output callback
        var outputCallback = AURenderCallbackStruct(inputProc: { inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, ioData in
            let refData_ = inRefCon.assumingMemoryBound(to: Echoback.RefConData.self).pointee
            
            let buf = UnsafeMutableAudioBufferListPointer(ioData)
            let data = refData_.soundBuf.dequeue()
            for buffer in buf! {
                memcpy(buffer.mData, data!.withUnsafeBytes{$0.baseAddress}, Int(data!.count))
            }
            return noErr
        }, inputProcRefCon: pRefData)
        status = AudioUnitSetProperty(refData.audioUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Global, 0, &outputCallback, UInt32(MemoryLayout<AURenderCallbackStruct>.size(ofValue: outputCallback)))
        if(status != noErr){
            print("AudioUnitSetProperty(kAudioUnitProperty_SetRenderCallback) failed.")
            abort()
        }
        
        // Activate AudioUnit
        status = AudioUnitInitialize(refData.audioUnit)
        if(status != noErr){
            print("AudioUnitInitialize failed.")
            abort()
        }
        
        // Play a dummy sound for remote command
        let path = Bundle.main.path(forResource: "appbeep", ofType: "wav")
        let url = URL(fileURLWithPath: path!)
        do{
            dummyPlayer = try AVAudioPlayer(contentsOf: url)
        }catch{
            print(error.localizedDescription)
            abort()
        }
        dummyPlayer.volume = 0
        dummyPlayer.numberOfLoops = -1
        dummyPlayer.play()
        
        // Set remote command handler
        let rcc = MPRemoteCommandCenter.shared()
        let handler = { [unowned self] (event:MPRemoteCommandEvent) in
            print("MPRemoteCommand invoked: \(event)")
            if(self.isRecording){
                self.stop()
            }else{
                self.start()
            }
            return MPRemoteCommandHandlerStatus.success
        }
        rcc.togglePlayPauseCommand.addTarget(handler: handler)
        rcc.playCommand.addTarget(handler: handler)
        rcc.pauseCommand.addTarget(handler: handler)
        rcc.stopCommand.addTarget(handler: handler)
    }
    var isRecording = false
    func start(){
        do{
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options:[.allowBluetooth,.defaultToSpeaker])
            try audioSession.overrideOutputAudioPort(.none)
            try audioSession.setActive(true)
        }catch{
            print(error.localizedDescription)
            abort()
        }
        AudioOutputUnitStart(refData.audioUnit)
        isRecording = true
    }
    func stop(){
        AudioOutputUnitStop(refData.audioUnit)
        isRecording = false
        refData.soundBuf.clear()
        do{
            try audioSession.setCategory(.playback, mode: .default)
            try audioSession.setActive(true)
        }catch{
            print(error.localizedDescription)
            abort()
        }
    }
}

class SoundDataQueue{
    private var queue = [(UInt64, Data)]()
    private let accessQueue = DispatchQueue(label: "Echoback", attributes: .concurrent)
    // Play with 5 sec delay
    private var delay = 5.0
    
    func enqueue(_ element: Data){
        accessQueue.async(flags: .barrier){
            self.queue.append((UInt64((Date().timeIntervalSince1970+self.delay)*1000),element))
        }
    }
    func dequeue() -> Data? {
        var element = Data()
        accessQueue.sync{
            let now = UInt64(Date().timeIntervalSince1970*1000)
            if(!self.queue.isEmpty && self.queue.first?.0 ?? 0 <= now){
                let data = self.queue.removeFirst()
                element.append(data.1)
            }
        }
        return element
    }
    func clear() {
        accessQueue.sync{
            self.queue.removeAll()
        }
    }
    var count: Int {
        var count = 0
        accessQueue.sync{
            count = self.queue.count
        }
        return count
    }
}
