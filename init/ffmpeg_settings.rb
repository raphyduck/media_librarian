$ffmpeg_crf = $config['ffmpeg_settings']['crf'] || 22 rescue 22
$ffmpeg_preset = $config['ffmpeg_settings']['preset'] || 'medium' rescue 'medium'