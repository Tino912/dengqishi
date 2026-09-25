extends Node
## Sound —— 程序化音效与背景乐。零外部素材（与 Web 版的 WebAudio 合成对应）。
##
## 做法：启动时用正弦/方波/三角波 + 噪声合成几段短 PCM，包成 AudioStreamWAV，
## 播放时轮转若干 AudioStreamPlayer（避免互相打断）。
## 音乐是一段可循环的低频长音，音量随连击强度变化 —— 「连击就是你的光」也听得见。

const RATE := 22050
const VOICES := 10

var enabled := true
var _players: Array[AudioStreamPlayer] = []
var _idx := 0
var _streams := {}
var _music: AudioStreamPlayer
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.seed = 20260924
	# 无头/纯逻辑模式不建音频节点，避免自检时出现无谓的驱动告警
	if DisplayServer.get_name() == "headless":
		enabled = false
		return
	for i in VOICES:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_players.append(p)

	_streams["slash"] = _tone(2400.0, 700.0, 0.11, 0.45, "sine", 0.45)
	_streams["hit"] = _tone(320.0, 140.0, 0.09, 0.50, "square", 0.32)
	_streams["crit"] = _tone(560.0, 190.0, 0.15, 0.60, "square", 0.28)
	_streams["coin"] = _tone(900.0, 1500.0, 0.10, 0.30, "tri", 0.0)
	_streams["dash"] = _tone(1200.0, 300.0, 0.16, 0.36, "sine", 0.65)
	_streams["skill"] = _tone(300.0, 1250.0, 0.28, 0.42, "tri", 0.05)
	_streams["hurt"] = _tone(190.0, 90.0, 0.20, 0.48, "square", 0.28)
	_streams["roar"] = _tone(95.0, 58.0, 0.52, 0.58, "square", 0.22)
	_streams["die"] = _tone(420.0, 70.0, 0.70, 0.48, "tri", 0.06)
	_streams["brazier"] = _tone(500.0, 940.0, 0.22, 0.34, "tri", 0.10)
	_streams["ui"] = _tone(700.0, 900.0, 0.07, 0.26, "tri", 0.0)
	_streams["ui_big"] = _tone(480.0, 1020.0, 0.18, 0.32, "tri", 0.0)
	_streams["levelup"] = _tone(620.0, 1480.0, 0.42, 0.36, "tri", 0.0)
	## 换手（X）与开箱：换手要"干脆"，开箱要"沉一点的吱呀"
	_streams["swap"] = _tone(880.0, 1320.0, 0.12, 0.30, "tri", 0.10)
	_streams["open"] = _tone(300.0, 760.0, 0.30, 0.34, "tri", 0.14)

	_music = AudioStreamPlayer.new()
	_music.stream = _drone()
	_music.volume_db = -22.0
	add_child(_music)
	_music.play()


func play(id: String) -> void:
	if not enabled or not _streams.has(id):
		return
	var p := _players[_idx]
	_idx = (_idx + 1) % _players.size()
	p.stream = _streams[id]
	p.volume_db = -6.0
	p.play()


## 连击强度 0..1 → 背景乐音量与亮度
func set_intensity(x: float) -> void:
	if not enabled or _music == null:
		return
	_music.volume_db = lerpf(-26.0, -12.0, clampf(x, 0.0, 1.0))
	_music.pitch_scale = lerpf(0.96, 1.08, clampf(x, 0.0, 1.0))


# ---------------------------------------------------------------- 合成

func _tone(f0: float, f1: float, dur: float, amp: float, shape := "sine", noise := 0.0) -> AudioStreamWAV:
	var n := int(RATE * dur)
	var s := PackedFloat32Array()
	s.resize(n)
	var phase := 0.0
	for i in n:
		var t := float(i) / float(n)
		var f := lerpf(f0, f1, t)
		phase += TAU * f / RATE
		var v := 0.0
		match shape:
			"square":
				v = 1.0 if sin(phase) > 0.0 else -1.0
			"tri":
				v = asin(sin(phase)) * 2.0 / PI
			_:
				v = sin(phase)
		if noise > 0.0:
			v += (_rng.randf() * 2.0 - 1.0) * noise
		var env := pow(maxf(0.0, 1.0 - t), 2.2)
		# 起音不要爆音
		env *= clampf(float(i) / (RATE * 0.004), 0.0, 1.0)
		s[i] = clampf(v, -1.0, 1.0) * amp * env
	return _wav(s)


## 8 秒可循环低频长音。三个不和谐度极低的频率叠在一起，加缓慢的音量起伏。
func _drone() -> AudioStreamWAV:
	var dur := 8.0
	var n := int(RATE * dur)
	var s := PackedFloat32Array()
	s.resize(n)
	var ph := [0.0, 0.0, 0.0]
	var freqs := [55.0, 82.41, 110.0]
	for i in n:
		var t := float(i) / RATE
		var v := 0.0
		for k in 3:
			ph[k] += TAU * freqs[k] / RATE
			v += sin(ph[k]) * [0.5, 0.28, 0.18][k]
		var lfo := 0.72 + 0.28 * sin(t * 0.28)
		s[i] = v * 0.20 * lfo
	# 首尾交叉淡化，循环点不爆音
	var fade := int(RATE * 0.25)
	for i in fade:
		var a := float(i) / float(fade)
		s[i] *= a
		s[n - 1 - i] *= a
	var w := _wav(s)
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_begin = 0
	w.loop_end = n
	return w


func _wav(s: PackedFloat32Array) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(s.size() * 2)
	for i in s.size():
		var v := int(clampf(s[i], -1.0, 1.0) * 32000.0)
		bytes.encode_s16(i * 2, v)
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = bytes
	return w
