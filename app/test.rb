class Test

  def djadja
    folder="/home/raph/media/tcompleted/Movies"
    ff=FileUtils.search_folder(folder,{'maxdepth'=>1, 'dironly'=>1}).map {|f| File.basename(f[0])}
    nonorphaned_folders=[]
    tids=$t_client.get_session_state
    tids.each do |tid|
      status = $t_client.get_torrent_status(tid, ['name', 'state'])
      nonorphaned_folders << ff.delete(status['name'])
    end
    ff.each do |f|
      p "Warning, folder '#{f}' is orphaned, will be removed"
      FileUtils.rm_r("/home/raph/media/tcompleted/Movies/#{f}")
    end
  end

end