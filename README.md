# movoa-swift

Unlimited AI video generator with sound: on paid plans the tenth take of a shot costs what the first did, and your first clip is free to make right now. This is the official Swift SDK for [Movoa](https://movoa.ai/?utm_source=cocoapods&utm_medium=package): make [text to video](https://movoa.ai/video/text-to-video) and [photo to video](https://movoa.ai/video/photo-to-video) clips from Swift code on your own Movoa account, and every clip comes back as [AI video with audio](https://movoa.ai/video/ai-video-with-audio).

```swift
import Movoa

let movoa = Movoa() // reads MOVOA_API_KEY
let clip = try await movoa.generateVideo("a lighthouse in a storm, waves crashing, distant thunder")
print(clip) // URL of the finished MP4
```

One call submits the run, waits for it and returns the URL of the finished file.

## Install

Swift Package Manager:

```swift
.package(url: "https://github.com/hanshs474/movoa-swift.git", from: "0.1.0")
```

CocoaPods:

```ruby
pod 'Movoa'
```

iOS 15+ / macOS 12+, no dependencies (`URLSession`).

## API key

Create a key at [movoa.ai/settings/apikeys](https://movoa.ai/settings/apikeys), then pass it as `Movoa(apiKey: "sk-...")` or export it:

```bash
export MOVOA_API_KEY=sk-...
```

Runs cost credits on your Movoa account, at the prices on https://movoa.ai/pricing. A run made here is queued and stored like one made on the site, so it shows up in your Movoa library too.

## Models and options

The default model is `minimax-h3` (6 seconds, 480p, 16:9). Sound is always on. Options go to the model as-is:

```swift
// Seedance 2.5: 10 seconds, vertical
try await movoa.generateVideo("a street drummer in the rain, handheld",
                              model: "seedance-2-5", options: ["duration": 10, "aspect_ratio": "9:16"])

// MiniMax H3 at 768p
try await movoa.generateVideo("a koi pond seen from above, petals falling",
                              options: ["duration": 8, "resolution": "768p"])
```

| model | what it is | options (default) |
|---|---|---|
| `minimax-h3` | MiniMax H3, the default | `duration` 4, 5, 6, 8, 10, 15 (6) · `resolution` 480p, 768p (480p) · `aspect_ratio` 16:9, 9:16, 1:1 (16:9) |
| `veo-3-1-fast` | Veo 3.1 Fast, see [Veo 3](https://movoa.ai/video/google-veo-3) | `duration` 8 · `resolution` 720p · `aspect_ratio` 16:9, 9:16 (photo to video: 16:9) |
| `seedance-2-5` | [Seedance 2.5](https://movoa.ai/video/seedance-2-5) | `duration` 5, 10, 15, 20, 25, 30 (5) · `resolution` 480p, 720p · `aspect_ratio` 16:9, 9:16, 1:1 |
| `seedance-2` | Seedance 2.0 | `duration` 4, 6, 8, 10 (6) · `resolution` 480p, 720p · `aspect_ratio` |
| `seedance-2-fast` | Seedance 2.0 Fast | same as `seedance-2` |
| `seedance-2-mini` | Seedance 2.0 Mini | same as `seedance-2` |

## Photo to video

Pass a public https image URL and it becomes the first frame; the prompt then describes the motion. This is the same [photo to video](https://movoa.ai/video/photo-to-video) flow as on the site:

```swift
try await movoa.generateVideo("the camera slowly orbits the statue",
                              imageURL: "https://example.com/statue.jpg")
```

## Submit now, collect later

```swift
let id = try await movoa.submit("a fox trotting through fresh snow")
let s = try await movoa.status(id)  // s.status: pending | processing | success | failed | canceled
let url = s.videoURL                // set once s.isSuccess
let left = try await movoa.credits()
```

`generateVideo` checks the run every 10 seconds and waits up to 30 minutes, since a run can sit in a queue; change that with the `pollInterval` and `timeout` properties. `wait(id)` waits for a run you submitted earlier.

## Errors worth catching

Every failure is a `Movoa.MovoaError`. Switch on the case:

- `.auth`: no key, or the key is wrong or deleted; create one at [movoa.ai/settings/apikeys](https://movoa.ai/settings/apikeys)
- `.rejected`: the content filter refused the prompt, or the account is cooling down after a refusal; reword rather than retry
- `.quota`: not enough credits left on the account for this run
- `.plan`: this model or quality needs a plan, or the account has not bought credits yet
- `.busy`: another generation on this account is still running; wait for it, then submit again
- `.generation(taskId:message:errorMessage:failureKind:)`: the run was accepted and then failed or was canceled; the service's error message comes with it
- `.timeout(taskId:)`: the wait ran out; the run may still finish, so look it up later by its task id

Anything else (a network failure, a 5xx) is `.api(status:message:)` with the service's message.

## License

MIT. Made by [Movoa](https://movoa.ai/?utm_source=cocoapods&utm_medium=package).
