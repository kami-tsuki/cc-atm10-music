# cc-atm10-music

`cc-atm10-music` is a revived CC: Tweaked music player built for ATM10 and other modpacks that include ComputerCraft or CC: Tweaked. The project is split into a server player and one or more remote clients:

- `startup` / `server` runs the main music player UI.
- `client` turns another computer into a remote speaker node.
- `lib/music/*` contains the full runtime, playlist loading, audio playback, networking, and UI framework.

The player reads playlist definitions from `config.json`, loads song indexes from GitHub repositories, streams `.dfpwm` files over HTTP, and can mirror playback to remote computers through Rednet.

## Features

- Non-interactive installer.
- Modular runtime under `lib/music`.
- Custom UI framework with panels, buttons, lists, badges, and progress bars.
- Playlist browser with a music-player style layout.
- Shuffle, loop off / loop all / loop one.
- Local speaker playback.
- Optional remote speaker clients over Rednet.
- Support for multiple playlist repositories.
- Flexible song indexes: JSON, legacy Lua table format, or line-based `index.txt`.

## Setup

### 1. Requirements

You need:

- CC: Tweaked with HTTP enabled.
- At least one speaker on the main machine.
- A modem or ender modem if you want remote clients.
- A monitor if you want the larger dedicated UI. The player also works directly in the terminal.

### 2. Install the player

Run this on the ComputerCraft computer that will host the player:

```sh
wget run https://raw.githubusercontent.com/kami-tsuki/cc-atm10-music/main/install.lua
```

The installer is intentionally non-interactive. It downloads the runtime, creates the `lib/music` folder, installs the launchers, and keeps your local `config.json` if it already exists.

Installed files:

- `startup.lua`
- `server.lua`
- `client.lua`
- `config.json`
- `lib/music/*.lua`

### 3. Start the host player

After installation:

```sh
startup
```

You can also run:

```sh
server
```

Both commands launch the same host player app.

### 4. Set up remote clients

On another computer with a speaker and modem:

```sh
wget run https://raw.githubusercontent.com/kami-tsuki/cc-atm10-music/main/install.lua
client
```

The client listens for playback commands from the server and plays the same track locally.

## Using The Player

### Mouse / touch controls

- Click a station on the left to switch playlists.
- Click a track on the right to start playback.
- Use the transport buttons for play/pause, stop, previous, next, shuffle, loop, reload, and volume.

### Keyboard controls

- `Up` / `Down`: move track selection.
- `Enter`: play the selected track.
- `Space`: play/pause.
- `Left` / `Right`: previous / next track.
- `[` / `]`: volume down / up.
- `S`: stop.
- `R`: reload the playlist library from `config.json`.

### Playback behavior

- The player stores playlist, track, volume, and playback settings with the ComputerCraft settings API.
- Shuffle and loop state are persisted.
- The server streams tracks from GitHub raw URLs.
- Clients receive play, stop, and volume messages over the `cc-atm10-music` Rednet protocol.

## Configuring Playlists

The player reads `config.json`. The file is a JSON array, or an object with a `playlists` array.

Each playlist entry supports:

- `name`: display name in the player UI.
- `repo`: GitHub repository in `owner/repo` form.
- `branch`: optional branch name, defaults to `main`.
- `index`: optional song index path, defaults to `index.txt`.

Example:

```json
[
	{
		"name": "My Playlist",
		"repo": "your-name/cc-music",
		"branch": "main",
		"index": "index.txt"
	},
	{
		"name": "Alt Branch Playlist",
		"repo": "your-name/another-music-repo",
		"branch": "release",
		"index": "music/index.json"
	}
]
```

## Creating Your Own Music Repository

You can host your own tracks on GitHub and point the player to them with `config.json`.

### 1. Create the repository structure

Example repository:

```text
my-cc-music/
	index.txt
	Night Drive.dfpwm
	Sunrise.dfpwm
	chill/
		After Hours.dfpwm
```

### 2. Create the song index

The player supports three index formats.

#### Option A: line-based `index.txt`

This is the easiest format.

```text
Night Drive
Sunrise
After Hours | chill/After Hours.dfpwm
```

Rules:

- A plain line means `display name == file name`.
- `Display Name | path/to/file.dfpwm` lets you separate the shown title from the real file path.
- Empty lines are ignored.
- Lines starting with `#` are treated as comments.

#### Option B: JSON index

Example `index.json`:

```json
[
	"Night Drive",
	{ "name": "After Hours", "file": "chill/After Hours.dfpwm" }
]
```

Or:

```json
{
	"songs": [
		"Night Drive",
		{ "name": "After Hours", "file": "chill/After Hours.dfpwm" }
	]
}
```

#### Option C: legacy Lua table format

This keeps compatibility with older repos:

```lua
{"Night Drive", "Sunrise", { name = "After Hours", file = "chill/After Hours.dfpwm" }}
```

### 3. Add the repository to `config.json`

Once the GitHub repo is public and contains your index plus `.dfpwm` files, add it to your local `config.json`:

```json
[
	{
		"name": "My Music",
		"repo": "your-name/my-cc-music",
		"branch": "main",
		"index": "index.txt"
	}
]
```

Then press `Reload` in the player or restart `startup`.

## Making Your Own Music Files

The player expects `.dfpwm` audio files because that is the format speakers can play efficiently in CC: Tweaked.

### Recommended preparation steps

Before converting:

- Trim silence at the start and end.
- Keep tracks reasonably short if you want faster GitHub downloads.
- Prefer mono source audio for more predictable results.
- Avoid very high volume masters; clipped audio sounds worse after conversion.

### Conversion workflow

If your `ffmpeg` build includes DFPWM support, the simplest command is:

```sh
ffmpeg -i input.mp3 -ar 48000 -ac 1 -c:a dfpwm "Track Name.dfpwm"
```

If your `ffmpeg` build does not include the DFPWM codec, convert through a DFPWM encoder tool instead. The exact tool varies, but the pipeline is usually:

1. Convert the source track to mono PCM WAV at 48 kHz.
2. Encode that WAV file into `.dfpwm`.
3. Upload the result into your GitHub music repo.

### Practical file naming guidance

- Spaces are supported.
- Nested folders are supported.
- Short, clean names are still easier to manage.
- Stick to public-safe filenames because the files are fetched through GitHub raw URLs.

### Final checklist for a new track

1. Convert the audio to `.dfpwm`.
2. Upload it to your GitHub music repository.
3. Add the track to your index file.
4. Ensure `config.json` points to the correct repo, branch, and index path.
5. Reload the library from the player UI.

## Project Structure

```text
startup.lua            Host launcher
server.lua             Host launcher alias
client.lua             Remote speaker launcher
install.lua            Non-interactive installer
config.json            Playlist repository config
lib/music/bootstrap.lua
lib/music/util.lua
lib/music/config.lua
lib/music/catalog.lua
lib/music/audio.lua
lib/music/network.lua
lib/music/ui.lua
lib/music/server_app.lua
lib/music/client_app.lua
```

## Notes

- The server and clients each download audio directly from GitHub.
- If a repo, branch, index, or track path is wrong, the player will surface the load failure in the UI.
- If you want to preserve a custom local `config.json`, rerunning the installer is safe because it does not overwrite an existing config file.
