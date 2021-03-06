require 'pathname'
require 'net/http'
require 'open-uri'
require 'fileutils'
require 'rubygems'
require 'nokogiri'
require 'net/https'

class Gisty
  VERSION   = '0.0.21'
  GIST_URL  = 'https://gist.github.com/'
  GISTY_URL = 'http://github.com/swdyh/gisty/tree/master'
  COMMAND_PATH = Pathname.new(File.join(File.dirname(__FILE__), 'commands')).realpath.to_s

  class UnsetAuthInfoException < Exception
  end

  class InvalidFileException < Exception
  end

  class PostFailureException < Exception
  end

  def self.extract_ids str
    doc = Nokogiri::HTML str
    doc.css('.file .info a').map { |i| i['href'].sub('/', '') }
  end

  def self.extract url
    doc = Nokogiri::HTML read_by_url(url)
    {
      :id => url.split('/').last,
      :author => doc.css('#owner a').inner_text,
      :files => doc.css('.meta .info').map { |i| i.inner_text.strip },
      :clone => doc.css('a[rel="#git-clone"]').inner_text,
    }
  end

  def initialize path, login = nil, token = nil, opt = {}
    @auth = (login && token) ? { 'login' => login, 'token' => token } : auth
    raise UnsetAuthInfoException if @auth['login'].nil? || @auth['token'].nil?
    @auth_query = "login=#{@auth['login']}&token=#{@auth['token']}"
    @dir  = Pathname.pwd.realpath.join path
    FileUtils.mkdir_p @dir unless @dir.exist?
    @ssl_ca = opt[:ssl_ca]
    @ssl_verify = case opt[:ssl_verify]
                  when /none/i
                    OpenSSL::SSL::VERIFY_NONE
                  else
                    OpenSSL::SSL::VERIFY_PEER
                  end
  end

  def next_link str
    doc = Nokogiri::HTML str
    a = doc.at('.pagination a[hotkey="l"]')
    a ? a['href'] : nil
  end

  def map_pages
    result = []
    base_url = GIST_URL.sub(/\/$/, '')
    path = "/mine?page=1"
    loop do
      url = base_url + path + "&#{@auth_query}"
      page = read_by_url(url)
      result << yield(url, page)
      path = next_link page
      break unless path
    end
    result
  end

  def remote_ids
    map_pages { |url, page| Gisty.extract_ids page }.flatten.uniq.sort
  end

  def clone id
    FileUtils.cd @dir do
      c = "git clone git@gist.github.com:#{id}.git"
      Kernel.system c
    end
  end

  def list
    dirs = Pathname.glob(@dir.to_s + '/*').map do |i|
      [i.basename.to_s,
       Pathname.glob(i.to_s + '/*').map { |i| i.basename.to_s }]
    end
    re_pub = /^\d+$/
    pub = dirs.select { |i| re_pub.match(i.first) }.sort_by { |i| i.first.to_i }.reverse
    pri = dirs.select { |i| !re_pub.match(i.first) }.sort_by { |i| i.first }
    { :public => pub, :private => pri }
  end

  def local_ids
    dirs = Pathname.glob(@dir.to_s + '/*')
    dirs.map { |i| i.basename.to_s }
  end

  def delete id
    FileUtils.rm_rf @dir.join(id) if @dir.join(id).exist?
  end

  def sync delete = false
    remote = remote_ids
    local  = local_ids

    if delete
      (local - remote).each do |id|
        print "delete #{id}? [y/n]"
        confirm = $stdin.gets.strip
        if confirm == 'y' || confirm == 'yes'
          puts "delete #{id}"
          delete id
        else
          puts "skip #{id}"
        end
      end
      ids = remote
    else
      ids = (remote + local).uniq
    end

    FileUtils.cd @dir do
      ids.each do |id|
        if File.exist? id
#           FileUtils.cd id do
#             c = "git pull"
#             Kernel.system c
#           end
        else
          c = "git clone git@gist.github.com:#{id}.git"
          Kernel.system c
        end
      end
    end
  end

  def pull_all
    ids = local_ids
    FileUtils.cd @dir do
      ids.each do |id|
        if File.exist? id
          FileUtils.cd id do
            c = "git pull"
            Kernel.system c
          end
        end
      end
    end
  end

  def auth
    user  = `git config --global github.user`.strip
    token = `git config --global github.token`.strip
    user.empty? ? {} : { 'login' => user, 'token' => token }
  end

  def post params
    url = URI.parse('https://gist.github.com/gists')
    req = Net::HTTP::Post.new url.path
    req.set_form_data params
    https = Net::HTTP.new(url.host, url.port)
    https.use_ssl = true
    https.verify_mode = @ssl_verify
    https.verify_depth = 5
    if @ssl_ca
      https.ca_file = @ssl_ca
    end
    res = https.start {|http| http.request(req) }
    case res
    when Net::HTTPSuccess, Net::HTTPRedirection
      res['Location']
    else
      raise PostFailureException, res.inspect
    end
  end

  def build_params paths
    list = (Array === paths ? paths : [paths]).map { |i| Pathname.new i }
    raise InvalidFileException if list.any?{ |i| !i.file? }

    params = {}
    list.each_with_index do |i, index|
      params["file_ext[gistfile#{index + 1}]"] = i.extname
      params["file_name[gistfile#{index + 1}]"] = i.basename.to_s
      params["file_contents[gistfile#{index + 1}]"] = IO.read(i)
    end
    params
  end

  def create paths, opt = { :private => false }
    params = build_params paths
    if opt[:private]
      params['private'] = 'on'
      params['action_button'] = 'private'
    end
    post params.merge(auth)
  end

  def read_by_url url
    if @ssl_ca
      url = URI.parse(url)
      req = Net::HTTP::Get.new url.request_uri
      https = Net::HTTP.new(url.host, url.port)
      https.use_ssl = true
      https.verify_mode = @ssl_verify
      https.verify_depth = 5
      https.ca_file = @ssl_ca
      res = https.start {|http| http.request(req) }
      case res
      when Net::HTTPSuccess
        res.body
      when Net::HTTPRedirection
        read_by_url res['Location']
      else
        raise 'get failure'
      end
    else
      open(url).read
    end
  end

  # `figlet -f contributed/bdffonts/clb8x8.flf gisty`.gsub('#', 'm')
  AA = <<-EOS
            mm                mm             
                              mm             
  mmmmmm  mmmm      mmmmm   mmmmmm   mm  mm  
 mm   mm    mm     mm         mm     mm  mm  
 mm   mm    mm      mmmm      mm     mm  mm  
  mmmmmm    mm         mm     mm      mmmmm  
      mm  mmmmmm   mmmmm       mmm       mm  
  mmmmm                               mmmm   
  EOS
end
