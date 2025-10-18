app = MediaLibrarian.app
settings = app.config['ffmpeg_settings'] || {}
app.ffmpeg_crf = settings['crf'] || 22
app.ffmpeg_preset = settings['preset'] || 'medium'