class_name Dictation
extends Node
## Hold-to-talk recording: the microphone on a silent bus with a capture effect; on release, the audio becomes a
## 16 kHz mono 16-bit WAV for the engine's transcription. Nothing is recorded while the key is not held.

signal level(value: float)

var bus := -1
var capture: AudioEffectCapture
var player: AudioStreamPlayer
var recording := false
var frames := PackedVector2Array()
var started_ms := 0


func _ready() -> void:
	bus = AudioServer.bus_count
	AudioServer.add_bus(bus)
	AudioServer.set_bus_name(bus, "Dictation")
	capture = AudioEffectCapture.new()
	capture.buffer_length = 5.0  # it is emptied at every frame; with 0.5 s, a half-second stall of the app lost words
	AudioServer.add_bus_effect(bus, capture)
	AudioServer.set_bus_volume_db(bus, -80.0)  # captured, never played back
	player = AudioStreamPlayer.new()
	player.bus = "Dictation"
	add_child(player)


func available() -> bool:
	return AudioServer.get_input_device_list().size() > 0


func start() -> void:
	frames = PackedVector2Array()
	capture.clear_buffer()
	if player.stream == null:
		player.stream = AudioStreamMicrophone.new()
	player.play()
	recording = true
	started_ms = Time.get_ticks_msec()


func _process(_d: float) -> void:
	if not recording:
		return
	var n := capture.get_frames_available()
	if n > 0:
		var chunk := capture.get_buffer(n)
		frames.append_array(chunk)
		var peak := 0.0
		for i in range(0, chunk.size(), 32):
			peak = maxf(peak, absf(chunk[i].x))
		level.emit(peak)


func stop() -> Dictionary:
	recording = false
	player.stop()
	var n := capture.get_frames_available()
	if n > 0:
		frames.append_array(capture.get_buffer(n))
	var seconds := (Time.get_ticks_msec() - started_ms) / 1000.0
	return {"wav": to_wav(frames, AudioServer.get_mix_rate()), "seconds": seconds}


## Stereo float frames at the mix rate -> WAV bytes, 16 kHz, mono, 16-bit (what transcription needs, small).
static func to_wav(src: PackedVector2Array, rate: float, out_rate := 16000) -> PackedByteArray:
	var step := rate / out_rate
	var count := int(src.size() / step)
	var pcm := PackedByteArray()
	pcm.resize(count * 2)
	for i in count:
		var f: Vector2 = src[mini(int(i * step), src.size() - 1)]
		var v := clampf((f.x + f.y) * 0.5, -1.0, 1.0)
		pcm.encode_s16(i * 2, int(v * 32767.0))
	var h := PackedByteArray()
	h.resize(44)
	h.encode_u32(0, 0x46464952)        # RIFF
	h.encode_u32(4, 36 + pcm.size())
	h.encode_u32(8, 0x45564157)        # WAVE
	h.encode_u32(12, 0x20746d66)       # fmt
	h.encode_u32(16, 16)
	h.encode_u16(20, 1)
	h.encode_u16(22, 1)
	h.encode_u32(24, out_rate)
	h.encode_u32(28, out_rate * 2)
	h.encode_u16(32, 2)
	h.encode_u16(34, 16)
	h.encode_u32(36, 0x61746164)       # data
	h.encode_u32(40, pcm.size())
	h.append_array(pcm)
	return h
