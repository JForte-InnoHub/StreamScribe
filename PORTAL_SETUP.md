# StreamScribe Web Portal — Setup

The web portal lets anyone on Windows, a phone, or another Mac use StreamScribe from a browser. StreamScribe keeps running exactly as it does today on the Mac Mini; the portal is just a second way to feed it work and read the results.

```
 Browser (Windows / iPhone / Mac)
        │  HTTPS
        ▼
 Cloudflare Access  ── email one-time code sign-in
        │
 Cloudflare Tunnel  ── outbound-only connection from the Mini; no router ports opened
        │
 cloudflared (on the Mac Mini) ──► http://127.0.0.1:8795
                                        │
                              StreamScribe.app (portal server, loopback only)
                                        │
                              Job queue ──► the one TranscriptionEngine
```

## How it behaves

- **One job at a time.** StreamScribe has one engine, so web requests go into a first-come, first-served queue. A live stream holds the engine until someone presses Stop.
- **The Mac stays in charge.** When the portal starts a job, its link appears in the Mac's URL field and the transcript streams into the Mac window as usual. A session someone starts at the Mac takes priority: queued web jobs wait until it finishes. The Mac's Start button and URL field are locked only for the few seconds the portal takes to start a job.
- **Links are checked as they're pasted.** Like the Mac's URL field, the page asks the Mini whether a link is a recording (and how long) or a live stream, and shows its title or why it can't be read. These checks never touch the Mac's own probe or a running job: they use a separate, stateless copy of the probe. Identical links share one check and a 10-minute cache, and at most two run at once, because each is a request from the Mini's internet connection. A failed check doesn't stop anyone submitting.
- **Per-job settings, then restored.** The form's **Options** pane holds source type (Auto / Live / Recording), engine (Auto / WhisperKit / Parakeet / Canary) and model. **Advanced** holds the speaker engine, expected speakers, language, start-from-the-beginning for live streams, and cleanup. Every control starts on the Mini's current setting. Only models already downloaded on the Mini can be chosen, so a job never starts a download mid-run. If an engine has nothing downloaded, portal admins see **Download to the Mac Mini** (with progress) in place of the model list; everyone else is asked to get an admin to do it. Downloads use the same R2 path as the Mac sidebar's Download buttons. After the job, the Mac's own settings are put back, unless someone changed that setting on the Mac mid-job, in which case their change is kept.
- **Edits stay in sync while the Mac still has the transcript.** Until the next session starts, speaker renames and pins made on the web go straight into the Mac app, and edits made on the Mac show up on the web. After that the web copy is kept on its own.
- **Exports match the Mac.** Downloads come from the same exporter and use the Mac's Settings → Transcript Export preferences.
- **Playback.** When a transcript finishes, its recording plays in a player above the transcript that stays in view while you scroll. The segment being spoken is highlighted and can be followed. Timestamps and "Play from here" jump to any point, and pinned quotes and selected sentences can be downloaded as video or audio clips. The Mac's media cache is wiped at every Start, so each job keeps its own copy of its recording, an APFS clone that takes no extra disk until one copy changes. Recordings are streamed in pieces, so seeking works over the tunnel and long videos never load into memory. Uploads that browsers can't play directly are converted once with the bundled ffmpeg. A transcript still running shows the player once it finishes.
- **Export options.** Next to Download, **Export options** offers the same six settings as the Mac's Settings → Transcript Export. They start from the Mini's own settings and each browser remembers its changes.
- **Who can do what.** Everyone who signs in can see every transcript and rename speakers or pin quotes. People can stop, cancel or delete their own jobs. Admins (listed in Settings) and anyone using the portal on the Mini itself can do that for any job and can pause the queue.
- **Storage.** Transcripts, uploads and each job's playback copy live in `~/Library/Application Support/StreamScribe/Portal/`. Finished jobs are removed after the retention period set in Settings (default 30 days); deleting a job deletes its upload and playback copy. Downloaded clips are kept for an hour.

## 1. Prepare the Mac Mini

1. Install StreamScribe and confirm a normal transcription works on the Mini first, including downloading the models you'll use (WhisperKit and Parakeet at least).
2. **System Settings → Users & Groups → Automatically log in as** the account that runs StreamScribe. The app has to be running in a logged-in session.
3. **System Settings → Energy:** turn on *Prevent automatic sleeping when the display is off* and *Start up automatically after a power failure*. (StreamScribe also holds a no-idle-sleep assertion while the portal is on.)
4. **System Settings → General → Login Items:** add StreamScribe so it launches at login.
5. Leave the StreamScribe window open (minimizing is fine).

## 2. Turn the portal on

1. StreamScribe → **Settings → Web Portal → Serve the web portal**.
2. The Server line should read **Running on 127.0.0.1:8795**. If it says *Address already in use*, pick another port and press Return.
3. Click **Open Portal on This Mac** and submit a short test link. The job should appear in the Mac window as it runs.
4. Add your own email under **Admins**.

The server only listens on 127.0.0.1. Nothing else on the network can reach it; the tunnel is the only way in.

## 3. Create the tunnel

You need a domain whose DNS is on Cloudflare (a subdomain such as `transcripts.yourdomain.com` works). A domain that has existed for a while is less likely to be blocked by corporate web filters than a newly registered one. Cloudflare Zero Trust has a free plan that covers up to 50 users.

Dashboard route (simplest):

1. Cloudflare dashboard → **Zero Trust → Networks → Tunnels → Create a tunnel → Cloudflared**. Name it `streamscribe`.
2. Choose **macOS**. Install `cloudflared` on the Mini (`brew install cloudflared`, or the `.pkg` from the cloudflared GitHub releases), then run the `sudo cloudflared service install <TOKEN>` command the dashboard shows. This installs a launch daemon, so the tunnel starts at boot.
3. Add a **Public Hostname**: subdomain `transcripts`, your domain, service type **HTTP**, URL **127.0.0.1:8795** (use `127.0.0.1`, not `localhost`).
4. The tunnel's status should show **Healthy**.

## 4. Protect it with Cloudflare Access — do this before sharing the link

New Zero Trust accounts sign people in with a **Cloudflare account** by default, so the login page asks for a Cloudflare email and password. The emailed-code method (One-time PIN) has to be added first, then chosen for this application.

**4a. Turn on One-time PIN** (once per account)

1. **Zero Trust → Integrations → Identity providers → Add new identity provider → One-time PIN.**
2. It saves immediately; there is nothing to configure.

**4b. Create the application**

1. **Zero Trust → Access controls → Applications → Create new application → Self-hosted and private → Add public hostname.**
2. Hostname: the same one the tunnel uses (`transcripts.yourdomain.com`), no path.
3. **Access policies:** create a policy named *Team*, action **Allow**, with an **Include** rule of **Emails ending in** `@yourcompany.com`. Add more domains, or **Emails** for individual outside addresses, in the same rule.
4. **Login methods:** turn off **Accept all available identity providers**, tick only **One-time PIN**, and turn on **Apply instant authentication**. Users then go straight to the "enter your email" box instead of a list of login choices.
5. **Session duration:** something like 1 week, so people aren't asked for a code constantly.
6. **Create**.

Codes are only emailed to addresses the policy allows. Anyone else sees the same "check your email" screen but never receives a code, so the page doesn't reveal who has access. The code comes from Cloudflare's notification address. If a corporate mail filter quarantines it, ask IT to allow that sender.

**Fail-safe:** if a request reaches the portal through Cloudflare *without* an Access identity (for example, the Access application is missing or its hostname has a typo), the portal refuses it with *"This portal must be reached through Cloudflare Access."* Seeing that message means Access isn't covering the hostname yet.

## 5. Check it end to end

- Open the hostname in a private window, or on a phone off Wi-Fi. You should see Cloudflare's "enter your email" page (not a Cloudflare account login). Enter an allowed address, type in the emailed code, and the portal should load with your email in the top-right corner.
- Submit a link, open the job, rename a speaker, pin a quote, and download a .docx.
- Upload a file larger than 100 MB. Uploads are sent in 16 MB pieces because Cloudflare rejects any single request over 100 MB. An interrupted piece is retried automatically.

## If the Mini moves onto the Netskope-managed network

The portal was built so a move onto a managed network costs as little as possible:

- **Nothing listens for inbound connections**, so firewall changes on the inbound side don't matter.
- **The page uses plain HTTPS requests only** — no WebSockets, which inspecting proxies often break. That matters for viewers on the managed fleet too.
- **Uploads are chunked** well below proxy and Cloudflare body limits.

Two things *will* be affected. Test them before the migration if you can (plug the Mini into a managed port for ten minutes):

**1. The tunnel's own connection.** cloudflared connects out to Cloudflare on **port 7844** (TCP for `http2`, UDP for `quic`) to `region1.v2.argotunnel.com` and `region2.v2.argotunnel.com`. It does not use 443, and there's no documented 443 fallback. Managed networks often block non-web ports, and TLS interception of that connection would break it.

```bash
nc -vz region1.v2.argotunnel.com 7844      # TCP 7844 reachable?
cloudflared tunnel --protocol http2 run --token <TOKEN>     # force TCP if UDP/QUIC is blocked
```

For a dashboard-managed tunnel, you can instead set the protocol in `/Library/LaunchDaemons/com.cloudflare.cloudflared.plist` (add `--protocol` `http2` before `run`) and reload the daemon. If 7844 is blocked or intercepted, the tunnel stays down no matter what's set on the Mac.

**2. YouTube throughput.** On the managed network the Mini would share the building's single Netskope egress IP, the one YouTube already throttles for the fleet. The same remedies as on the laptops apply: a dedicated static ISP proxy in StreamScribe's proxy fallback list, and the TLS-check toggle for yt-dlp.

**The cleanest fix for both** is to keep the Mini on its own internet connection even after the LAN migration — for example, a small separate ISP line or a 5G router used only by the Mini. The tunnel and YouTube both stay off the managed egress, and nothing in the portal changes.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Browser shows *must be reached through Cloudflare Access* | The Access application doesn't cover this hostname. See step 4. |
| Cloudflare error 502 | The tunnel is up but StreamScribe isn't serving. Open the app and check Settings → Web Portal. |
| Cloudflare error 1033 | The tunnel is down. Check `sudo launchctl list \| grep cloudflared` and the tunnel's status in the dashboard. |
| Server line says *Address already in use* | Another app has the port. Pick a new port, then update the tunnel's service URL to match. |
| Job sits at *Waiting for a session started on the Mac to finish* | Someone is running a session on the Mac. It starts automatically when that ends. |
| Job failed with a model error | That engine's model isn't downloaded on the Mini. Download it in the Mac app. |
| "Your sign-in has expired" banner | The Access session timed out. Reload the page. |
| Anything else | StreamScribe's log viewer: every portal line starts with `[Portal]`. |

## What changed in the code

New files (add to the StreamScribe target):

- `Services/Portal/PortalHTTP.swift` — loopback-only HTTP/1.1 server on Network.framework (Content-Length and chunked bodies, 64 MB cap, per-connection timeout).
- `Services/Portal/PortalModels.swift` — job model, per-job settings apply/restore, transcript revision index, wire types.
- `Services/Portal/PortalJobQueue.swift` — the queue that drives the engine, persistence, identity, and all API routes.
- `Services/Portal/PortalPage.swift` — the web page, generated from `portal-web/portal.html` by `python3 portal-web/gen_page.py`. Edit the HTML and regenerate rather than editing the Swift string.
- `Views/PortalSettingsSection.swift` — Settings → Web Portal.

Small edits to existing files:

- `TranscriptionEngine.swift`:
  - `setTranscriptionEngineFromPortal(_:)` sets the engine without pinning it or firing the Sortformer autopair.
  - `portalEngineChoiceActive` stops the per-mode default (which re-runs inside `start()`) from overriding a job's engine choice.
  - `sessionGeneration` is bumped in `start()` and gives each session a stable identity (`sessionStartedAt` is cleared at every session end, so it can't serve).
  - `probeGeneration` / `lastProbeInput` are bumped in `beginProbe`.
- `StreamScribeApp.swift` — `.task { PortalJobQueue.shared.attach(engine:) }`.
- `ContentView.swift` — mirrors the portal's current job into the URL field.
- `SidebarView.swift` — Start, the URL field and Choose File are disabled while the portal is starting a job (`ContentView`'s file drop too), so the Mac can't re-probe a different input mid-dispatch.
- `SettingsView.swift` — adds `PortalSettingsSection()`.
