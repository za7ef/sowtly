# Privacy Policy

Last updated: November 2026

In short: **your data stays on your device.** The app has no servers of its own and doesn't collect anything about you. The only exception is optional: cloud models (for chat and calls) if you turn them on yourself with your own key (see below).

## What the App Doesn't Do

- No accounts and no sign-in.
- No ads, no trackers, and no usage analytics.
- Your chats, voice, and files aren't sent to the app's developer or to anyone else, except to a cloud provider you turned on yourself.

## What's Stored on Your Device

All of this is stored inside the app, protected by device encryption, and erased if you delete the app:

- **Chats:** You can delete any chat from the list.
- **Memory:** Short facts the app infers about you from your chats so it understands you better. You can view, edit, delete them all, or turn memory off in Settings → Memory.
- **Your name and form of address:** If you entered them in Settings. Optional.
- **Attached images and files:** A small copy of the image and the text extracted from the file, inside the chat.
- **Diagnostic log:** Technical info (memory, temperature, errors) without the text of your chats. It never leaves your device unless you export and send it yourself.

## Permissions

- **Microphone:** For calls and dictation. Audio is processed in real time and isn't saved.
- **Speech Recognition:** If you choose "Apple Speech Recognition". See the note below.
- **Camera, Photos, and Files:** Only when you choose to attach something yourself.
- **Camera during calls:** Always off unless you turn it on. While it's on, one small frame is taken at the end of each thing you say and is seen by the model on your device; it isn't saved and never leaves the device. It turns off when the call ends or when you leave the app.

## A Note on Apple Speech

"Apple Speech Recognition" uses iOS speech recognition. If your device supports your language on-device, everything is processed on the device. **If it doesn't, the app won't use it unless you turn on "Allow Apple Speech Recognition to Use the Internet" yourself**, in which case iOS sends the audio to Apple's servers under Apple's Privacy Policy.

## Internet

The message field has an **Internet** button (the globe icon). It's the only switch for the app's internet connection:

- **When it's off:** The app doesn't connect to the internet. If you need to download a model or a voice, or you tap "Check for Updates", it asks you first and you can allow it for that one time only. Automatic update checks don't run.
- **When you turn it on:** You see a notice first. After that, for each text message you send, the app sends **only the text of your question** to the **DuckDuckGo** search engine (or **Wikipedia** if nothing comes back), and opens the first 3–4 result pages to read them. Requests have no cookies, account, or key, and don't include your previous chats, memory, or attachments. Reading the pages and writing the answer all happen on your device, and the sources appear below the reply.
- **Downloads:** Models come from **Hugging Face**, and the NAMAA voice and its reference from Hugging Face and GitHub. These sites, the search engine, and the pages that are opened see the normal request (such as your IP address) under their own policies.
- **Updates:** The check reads a small public file from GitHub, without sending any data about you.
- **Developer Disk Image (Device Control only):** When needed, Apple's Developer Disk Image (about 18 MB) is downloaded once from a public copy on GitHub (doronz88/DeveloperDiskImage), and a signing request containing the device's chip identifiers is sent to Apple's signing server (gs.apple.com), the same request Xcode sends. None of your content is sent.

Voice calls never use search.

## Cloud Models for Chat (Optional)

In Models → "Cloud Models" you can use a cloud model (free Gemini, free OpenRouter models, or paid ChatGPT, Claude, or Gemini) with your own key. You see a notice once before the first use. While it's on:

- Every message you send in chat goes to the provider's servers along with **the previous conversation**, the app's instructions (including your memory and name if enabled), **attached images and files**, and search results if it searched. Background tasks such as memory extraction go to it as well.
- **Calls** stay local unless you turn on "Use in Calls Too"; then the transcribed text of what you say (not the audio) and the camera frame, if the camera is on, go to the provider.
- Data goes from your device straight to the provider (it doesn't pass through the app's developer) and is subject to the provider's policy. Free tiers may use it to improve their services.
- Keys are stored only in the keychain on your device, and you can delete them. Tap "Back to Local" to return to the on-device model, and then nothing leaves the device.

## Image Generation

- **Stable Diffusion:** Generates entirely on your device; nothing leaves it.
- **Image Playground:** Apple's window opens with the description and you confirm it yourself. On iOS 27, Apple generates on its own cloud (Private Cloud Compute) and says the data isn't stored or shared, even with Apple. Requires internet and is subject to Apple's policy.
- **Gemini:** The description goes to Google's servers with your key and is subject to Google's policy.

## Children

The app isn't intended for children under 13.

## Contact

For any privacy question, contact the developer on [GitHub](https://github.com/za7ef).
