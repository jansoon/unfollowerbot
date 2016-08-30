require 'open-uri'
require 'json'
require 'set'
require 'mail'
require 'erb'
require 'tzinfo'
require 'logger'
require 'fileutils'

class Twitch
  def self.followers(channel)
    names = Set.new

    last_request = Time.now

    follows_urls(channel) do |url|
      # Sleep 1 second between requests.
      now = Time.now
      delta = now - last_request
      delay = [1 - delta, 0].max
      sleep delay

      json = JSON.parse(open(url, 'Accept' => 'application/vnd.twitchtv.v3+json').read)
      last_request = now

      batch = json['follows'].map { |f| f['user']['name'] }
      break if batch.empty?
      names += batch
    end

    names.to_a
  end

  def self.follows_urls(channel)
    offset = 0
    loop do
      yield "https://api.twitch.tv/kraken/channels/#{channel}/follows?limit=100&offset=#{offset}&direction=ASC"
      offset += 80
    end
  end
end

class Diff
  def initialize(before, after)
    @before = before.dup
    @after = after.dup

    all_names = Set.new(@before + @after)
    original_names = Hash[all_names.map(&:downcase).zip(all_names)]

    @before.map!(&:downcase)
    @after.map!(&:downcase)

    @removed = before - after
    @added = after - before

    @removed.map! { |name| original_names[name] }
    @added.map! { |name| original_names[name] }
  end

  def removed
    @removed
  end

  def added
    @added
  end
end

class Snapshot
  def Snapshot.create(channel)
    $log.info "Creating snapshot for #{channel}."
    followers = Twitch.followers(channel)
    Snapshot.new(channel, followers)
  end

  def Snapshot.load(filename)
    File.open(filename, 'r') do |f|
      obj = JSON.parse(f.read)
      timestamp = Time.parse(obj['timestamp'])
      return Snapshot.new(obj['channel'], obj['followers'], timestamp)
    end
  end

  def save(filename)
    File.open(filename, 'w') do |f|
      snapshot = {
        channel: @channel,
        timestamp: @timestamp,
        followers: @followers
      }
      f.write JSON.dump(snapshot)
    end
  end

  attr_accessor :channel, :followers, :timestamp

  private

  def initialize(channel, followers, timestamp = Time.now.utc)
    @channel = channel
    @followers = followers
    @timestamp = timestamp
  end
end

class Report
  def initialize(before, after)
    @before = before
    @after = after
    @diff = Diff.new(before.followers, after.followers)
  end

  def before
    @before
  end

  def after
    @after
  end

  def removed
    @diff.removed
  end

  def added
    @diff.added
  end

  def email(emails)
    Mail.defaults do
      delivery_method :smtp, {
        address: 'smtp.gmail.com',
        port: 587,
        user_name: 'unfollowerbot@gmail.com',
        password: ENV['UNFOLLOWERBOT_EMAIL_PASSWORD'],
        authentication: 'plain',
        enable_starttls_auto: true
      }
    end

    Mail.deliver do
      to emails
      from 'unfollowerbot <unfollowerbot@gmail.com>'
      subject "Twitch follower report for #{Time.now.strftime('%m/%d')}"

      html_part do
        content_type 'text/html; charset=UTF-8'
        body self.html
      end
    end
  end

  private

  def html
    template_path = File.absolute_path(File.join(File.dirname(__FILE__), 'report.html.erb'))
    template = ERB.new(File.read(template_path))
    return template.result(binding)
  end
end

class SnapshotReportManager
  def initialize(snapshot_dir)
    @snapshot_dir = snapshot_dir
  end

  def update(channel, emails)
    FileUtils.mkdir_p(@snapshot_dir)
    snapshot_filename = "#{@snapshot_dir}/#{channel.downcase}.json"

    begin
      $log.info 'Loading previous snapshot.'
      before = Snapshot.load(snapshot_filename)
    rescue Errno::ENOENT
      $log.info 'Previous snapshot not found.'
    end

    after = Snapshot.create(channel)

    if before && after
      report = Report.new(before, after)
      if report.removed.empty? && report.added.empty?
        $log.info 'No new followers or unfollowers, not sending report.'
        return
      else
        $log.info "Sending report to #{emails.join(', ')} for #{channel}."
        report.email(emails)
      end
    else
      $log.info 'No snapshot to compare with, not sending report.'
    end

    after.save(snapshot_filename)
  end
end

$log = Logger.new(STDOUT)
$log.level = Logger::DEBUG

channel = ARGV[0]
emails = ARGV[1]

if !channel || !emails
  $log.error 'Usage: snapshot <twitch channel> <emails>'
  exit 1
end

$log.info "Doing snapshot update for #{channel}."
snapshot_dir = File.absolute_path(File.join(File.dirname(__FILE__), 'snapshots'))
manager = SnapshotReportManager.new(snapshot_dir)
manager.update(channel, emails.split(';'))
$log.info 'Fin.'
