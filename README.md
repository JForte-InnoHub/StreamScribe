StreamScribe is an on-device transcription app designed for Apple Silicon Macs. It uses MLX/CoreML versions of Whisper and Parakeet for transcription, and SpeakerKit and Softformer for diarization. Downloading is handled via bundled yt-dlp and ffmpeg. 

**StreamScribe Guide**

How to install:

1. Download StreamScribe-release.dmg and double click it. Drag the StreamScribe app to your Desktop or any other folder (admin access is required to drag into /Applications). 

2. Run StreamScribe. It should automatically detect the models in your Documents folder. If you are subject to Netskope, the initial download from Huggingface will fail, and StreamScribe will download the models from my R2 mirror instead. 

4. Set your “Cookies” selector to whichever browser you use most. This allows StreamScribe to borrow your YouTube cookies to avoid automatic bot detection. For most users, this will be Chrome. On your first transcription run, StreamScribe will prompt for keychain access so it can borrow the cookies - please enter your password and choose “Always allow”. 

6. You are all set and ready to start transcribing! If you encounter issues with the application, please contact Jamie Forte (jforte@omc.com) for help troubleshooting.

How to use:

Paste a URL into the box in the top left. StreamScribe will probe and identify the linked stream/content and automatically select the best method to download and transcribe it.
Hit “Start” and give StreamScribe a few seconds to spin up and start working. 
Once finished, you can label speakers using the speaker panel in the top right and then export the finished transcript with the button next to “Start/Stop”. 

Other helpful notes/tips:

- Whisper and SpeakerKit are best for finite length content, while Parakeet and Softformer are ideal for ongoing livestreams where latency matters. To get both fast transcription and accuracy on live streams, enable “Multi-pass refinement”, “Use a different engine for refined pass” and “Re-diarize with SpeakerKit when finished”. This will use parakeet and softformer for the initial pass, and retroactively correct the transcript with Whisper and Speakerkit as more stream audio becomes available.
- StreamScribe can transcribe any language, but works best with English. 
- The keyword spotting feature allows you to automatically pin transcript segments with relevant keywords as they arise. You can review pinned segments with the pin button in the top right. Enabling the “Notify on hit” switch will cause StreamScribe to send you a system notification whenever a keyword is mentioned in the transcript. You may need to give StreamScribe notification permissions in your MacOS settings for this feature to work.
- You can adjust transcript formatting in the settings menu (StreamScribe>Settings in the top bar)
- Once transcription has finished, the play button in the top right corner will allow you to replay the content and the transcript will follow along automatically. This can be helpful for identifying and filling in speaker labels (e.g. “Speaker 1” -> “President Trump”)
- If you encounter performance issues, you can increase your MLX buffer cache limit to 1024 MB or greater in Settings.
- If StreamScribe randomly stops working one day, it may be because YouTube changed how their backend works. To fix this, click the “Update yt-dlp Now” button in the bottom left.
You can also export transcribed videos along with their transcripts using the button in the bottom left of the transcript export window. This can be useful for downloading YouTube and other videos. 
