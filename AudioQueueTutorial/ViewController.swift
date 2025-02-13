//
//  ViewController.swift
//  AudioQueueTutorial
//
//  Created by tomisacat on 19/04/2017.
//  Copyright © 2017 tomisacat. All rights reserved.
//

import AVFAudio
import Combine
import UIKit

class ViewController: UIViewController {
    @IBOutlet weak var progressSlider: UISlider!
    @IBOutlet var currentTimeLabel: UILabel!
    @IBOutlet weak var durationLabel: UILabel!
    var player: AudioQueuePlayer?
    var cancellables = Set<AnyCancellable>()

    override func viewDidLoad() {
        super.viewDidLoad()

        setAudioSession()

        guard let path = Bundle.main.path(forResource: "Avid", ofType: "flac") else {
            return
        }

        let url = URL(fileURLWithPath: path)
        guard let player = AudioQueuePlayer(url: url) else { return }
        self.player = player

        durationLabel.text = timeString(player.duration)
        progressSlider.minimumValue = 0
        progressSlider.maximumValue = Float(player.duration)
        player.currentTimePublisher.sink { [weak self] currentTime in
            guard let self else { return }
            self.progressSlider.value = Float(currentTime)
            self.currentTimeLabel.text = self.timeString(currentTime)
        }.store(in: &cancellables)
    }

    func setAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback,
                                    mode: .default,
                                    policy: .longFormAudio
            )
            try session.setActive(true)
        } catch {
            print("Failed to set audio session category. Error: \(error.localizedDescription)")
        }
    }

    private func timeString(_ time: TimeInterval) -> String {
        let seconds = Int(time) % 60
        let minutes = Int(time) / 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    @IBAction func playButtonClicked(sender: UIButton) {
        if player?.playing == true {
            player?.pause()
            sender.setImage(.init(systemName: "play.fill"), for: .normal)
        } else {
            player?.play()
            sender.setImage(.init(systemName: "pause.fill"), for: .normal)
        }
    }
}

