//
//  AudioQueuePlayer.swift
//  AudioQueueTutorial
//
//  Created by tomisacat on 19/04/2017.
//  Copyright © 2017 tomisacat. All rights reserved.
//

import AudioToolbox
import AVFoundation
import Combine

fileprivate func audioQueueOutputCallback(inUserData: UnsafeMutableRawPointer?, inQueue: AudioQueueRef, inBuffer: AudioQueueBufferRef) {
    guard let playerPointer = inUserData else {
        return
    }
    let player = Unmanaged<AudioQueuePlayer>.fromOpaque(playerPointer).takeUnretainedValue()

    var bufferLength: UInt32 = player.info.bufferByteSize
    var numPkgs: UInt32 = kNumberPackages
    var status = AudioFileReadPacketData(player.info.mAudioFile!,
                                         false,
                                         &bufferLength,
                                         player.info.mPacketDesc,
                                         player.info.mCurrentPacket,
                                         &numPkgs,
                                         inBuffer.pointee.mAudioData)
    if status == noErr {
        inBuffer.pointee.mAudioDataByteSize = bufferLength
    }

    status = AudioQueueEnqueueBuffer(inQueue,
                                     inBuffer,
                                     numPkgs,
                                     player.info.mPacketDesc)
    if status == noErr {
        player.info.mCurrentPacket += Int64(numPkgs)
    }

    if numPkgs == 0 {
        player.stop()
    }
}

fileprivate struct PlayerInfo {
    var mDataFormat: AudioStreamBasicDescription?
    var mQueue: AudioQueueRef?
    var mBuffers: [AudioQueueBufferRef] = []
    var mAudioFile: AudioFileID?
    var bufferByteSize: UInt32 = 0
    var mCurrentPacket: Int64 = 0
    var mPacketDesc: UnsafeMutablePointer<AudioStreamPacketDescription>?
    var currentTime: AudioTimeStamp = AudioTimeStamp()
    var duration: Float64 = 0
}

fileprivate let kNumberBuffers: UInt32 = 3
fileprivate let kNumberPackages: UInt32 = 100

public class AudioQueuePlayer {
    // property
    fileprivate var audioFileUrl: URL
    fileprivate var info: PlayerInfo = PlayerInfo()
    private(set) public var playing: Bool = false
    var duration: TimeInterval {
        info.duration
    }
    private let currentTimeSubject: CurrentValueSubject<TimeInterval, Never> = .init(0)
    var currentTimePublisher: any Publisher<TimeInterval, Never> {
        currentTimeSubject.removeDuplicates {
            abs($0 - $1) < 0.5
        }
    }
    var cancellables = Set<AnyCancellable>()

    // life cycle
    init?(url: URL) {
        audioFileUrl = url

        var audioFile: AudioFileID?
        if AudioFileOpenURL(url as CFURL, .readPermission, 0, &audioFile) == noErr {
            info.mAudioFile = audioFile
        } else {
            return nil
        }

        var descSize: UInt32 = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var dataFormat = AudioStreamBasicDescription()
        var status = AudioFileGetProperty(audioFile!, kAudioFilePropertyDataFormat, &descSize, &dataFormat)
        guard status == noErr else {
            return nil
        }
        info.mDataFormat = dataFormat

        var durationSize: UInt32 = UInt32(MemoryLayout<Float64>.size)
        status = AudioFileGetProperty(audioFile!, kAudioFilePropertyEstimatedDuration, &durationSize, &info.duration)
        guard status == noErr else {
            return nil
        }

        var queue: AudioQueueRef?

        let pointerToSelf = Unmanaged.passUnretained(self).toOpaque()
        status = AudioQueueNewOutput(&dataFormat,
                                     audioQueueOutputCallback,
                                     pointerToSelf,
                                     CFRunLoopGetCurrent(),
                                     CFRunLoopMode.commonModes.rawValue,
                                     0,
                                     &queue)
        guard status == noErr else {
            return nil
        }
        info.mQueue = queue

        var maxPacketSize: UInt32 = 0
        var propertySize: UInt32 = UInt32(MemoryLayout<UInt32>.size)
        if AudioFileGetProperty(audioFile!, kAudioFilePropertyPacketSizeUpperBound, &propertySize, &maxPacketSize) == noErr {
            info.bufferByteSize = kNumberPackages * maxPacketSize
            info.mPacketDesc = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: Int(kNumberPackages))
        } else {
            return nil
        }

        var cookieSize: UInt32 = UInt32(MemoryLayout<UInt32>.size)
        if AudioFileGetPropertyInfo(audioFile!, kAudioFilePropertyMagicCookieData, &cookieSize, nil) == noErr {
            let magicCookie: UnsafeMutablePointer<CChar> = UnsafeMutablePointer<CChar>.allocate(capacity: Int(cookieSize))
            AudioFileGetProperty(audioFile!, kAudioFilePropertyMagicCookieData, &cookieSize, magicCookie)
            AudioQueueSetProperty(queue!, kAudioQueueProperty_MagicCookie, magicCookie, cookieSize)
            magicCookie.deallocate()
        }

        info.mCurrentPacket = 0

        for _ in 0..<kNumberBuffers {
            var buffer: AudioQueueBufferRef?
            if AudioQueueAllocateBuffer(queue!, info.bufferByteSize, &buffer) == noErr {
                info.mBuffers.append(buffer!)
                audioQueueOutputCallback(inUserData: pointerToSelf, inQueue: queue!, inBuffer: buffer!)
            } else {
                return nil
            }
        }

        AudioQueueSetParameter(queue!, kAudioQueueParam_Volume, 1.0)

        Timer.publish(every: 0.1, on: .current, in: .common).autoconnect().sink { [weak self] _ in
            self?.updateCurrentTime()
        }.store(in: &cancellables)
    }

    deinit {
        if let audio = info.mAudioFile {
            AudioFileClose(audio)
            info.mAudioFile = nil
        }

        if let queue = info.mQueue {
            AudioQueueDispose(queue, true)
            info.mQueue = nil
        }

        if let desc = info.mPacketDesc {
            desc.deallocate()
            info.mPacketDesc = nil
        }
    }

    private func updateCurrentTime() {
        guard let queue = info.mQueue else { return }
        var timeStamp = AudioTimeStamp()
        let status = AudioQueueGetCurrentTime(
            queue,
            nil,
            &timeStamp,
            nil
        )
        if status == noErr {
            info.currentTime = timeStamp
        }
        currentTimeSubject.send(info.currentTime.mSampleTime / info.mDataFormat!.mSampleRate)
    }

    func stop() {
        guard let queue = info.mQueue else { return }
        AudioQueueStop(queue, true)
        playing = false
    }
}

// function
extension AudioQueuePlayer {
    func play() {
        playing = true
        AudioQueueStart(info.mQueue!, nil)
    }

    func pause() {
        playing = false
        AudioQueuePause(info.mQueue!)
    }
}
