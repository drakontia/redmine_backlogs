require 'pp'

class RbIssueHistory < ActiveRecord::Base
  self.table_name = 'rb_issue_history'
  belongs_to :issue

  serialize :history, Array
  after_initialize :set_default_history
  after_save :touch_sprint

  def self.statuses
    Hash.new{|h, k|
      s = IssueStatus.find_by_id(k.to_i)
      if s.nil?
        s = IssueStatus.default
        puts "IssueStatus #{k.inspect} not found, using default #{s.id} instead"
      end
      h[k] = {:id => s.id, :open => ! s.is_closed?, :success => s.is_closed? ? (s.default_done_ratio.nil? || s.default_done_ratio == 100) : false }
      h[k]
    }
  end

  def filter(sprint, status=nil)
    h = Hash[*(self.expand.collect{|d| [d[:date], d]}.flatten)]
    filtered = sprint.days.collect{|d| h[d] ? h[d] : {:date => d, :origin => :filter}}
    
    # see if this issue was closed after sprint end
    if filtered[-1][:status_open]
      self.history.select{|h| h[:date] > sprint.effective_date}.each{|h|
        if h[:sprint] == sprint.id && !h[:status_open]
          filtered[-1] = h
          break
        end
      }
    end
    return filtered
  end

  def self.issue_type(tracker_id)
    return nil if tracker_id.nil? || tracker_id == ''
    tracker_id = tracker_id.to_i
    return :story if RbStory.trackers && RbStory.trackers.include?(tracker_id)
    return :task if tracker_id == RbTask.tracker
    return nil
  end

  def expand
    (0..self.history.size - 2).to_a.collect{|i|
      (self.history[i][:date] .. self.history[i+1][:date] - 1).to_a.collect{|d|
        self.history[i].merge(:date => d)
      }
    }.flatten
  end

  def self.rebuild_issue(issue, status=nil)
    rb = RbIssueHistory.new(:issue_id => issue.id)

    rb.history = [{:date => issue.created_on.to_date - 1, :origin => :rebuild}]

    status ||= self.statuses

    convert = lambda {|prop, v|
      if v.nil?
        nil
      elsif [:estimated_hours, :remaining_hours, :story_points].include?(prop)
        Float(v)
      else
        Integer(v)
      end
    }

    full_journal = {}
    issue.journals.each{|journal|
      date = journal.created_on.to_date

      ## TODO: SKIP estimated_hours and remaining_hours if not a leaf node
      journal.details.each{|jd|
        next unless jd.property == 'attr' && ['estimated_hours', 'story_points', 'remaining_hours', 'fixed_version_id', 'status_id', 'tracker_id'].include?(jd.prop_key)

        prop = jd.prop_key.intern
        update = {:old => convert.call(prop, jd.old_value), :new => convert.call(prop, jd.value)}

        full_journal[date] ||= {}

        case prop
        when :estimated_hours, :remaining_hours # these sum to their parents
          full_journal[date][prop] = update
        when :story_points
          full_journal[date][prop] = update
        when :fixed_version_id
          full_journal[date][:sprint] = update
        when :status_id
          [:id, :open, :success].each_with_index{|status_prop, i|
            full_journal[date]["status_#{status_prop}".intern] = {:old => status[update[:old]][status_prop], :new => status[update[:new]][status_prop]}
          }
        when :tracker_id
          full_journal[date][:tracker] = {:old => RbIssueHistory.issue_type(update[:old]), :new => RbIssueHistory.issue_type(update[:new])}
        else
          raise "Unhandled property #{jd.prop}"
        end
      }
    }
    full_journal[issue.updated_on.to_date] = {
      :story_points => {:new => issue.story_points},
      :sprint => {:new => issue.fixed_version_id },
      :status_id => {:new => issue.status_id },
      :status_open => {:new => status[issue.status_id][:open] },
      :status_success => {:new => status[issue.status_id][:success] },
      :tracker => {:new => RbIssueHistory.issue_type(issue.tracker_id) },
      :estimated_hours => {:new => issue.estimated_hours},
      :remaining_hours => {:new => issue.remaining_hours},
    }

    # Wouldn't be needed if redmine just created journals for update_parent_properties
    subissues = Issue.find(:all, :conditions => ['parent_id = ?', issue.id]).to_a
    subhists = []
    subdates = []
    subissues.each{|i|
      subdates.concat(i.history.history.collect{|h| h[:date]})
      subhists << Hash[*(i.history.expand.collect{|d| [d[:date], d]}.flatten)]
    }
    subdates.uniq!
    subdates.sort!

    subdates.sort.each{|date|
      next if date < issue.created_on.to_date

      current = {}
      full_journal.keys.sort.select{|d| d <= date}.each{|d|
        current[:sprint] = full_journal[d][:sprint][:new] if full_journal[d][:sprint]
        current[:estimated_hours] = full_journal[d][:estimated_hours][:new] if full_journal[d][:estimated_hours]
        current[:remaining_hours] = full_journal[d][:remaining_hours][:new] if full_journal[d][:remaining_hours]
        current[:tracker] = full_journal[d][:tracker][:new] if full_journal[d][:tracker]
      }
      next unless current[:tracker] # only process issues that exist at that date and are either story or task

      change = {
        :sprint => [],
        :estimated_hours => [],
        :remaining_hours => [],
      }
      subhists.each{|h|
        [:sprint, :remaining_hours, :estimated_hours].each{|prop|
          change[prop] << h[date][prop] if h[date] && h[date].include?(prop)
        }
      }
      change[:sprint].uniq!
      change[:sprint].sort!{|a, b|
        if a.nil? && b.nil?
          0
        elsif a.nil?
          1
        elsif b.nil?
          -1
        else
          a <=> b
        end
      }
      puts "#{current[:tracker][:new]} #{issue.id} has tasks on multiple sprints: #{change[:sprint].inspect}, picking #{change[:sprint][0]} at random" if change[:sprint].size > 1

      [:remaining_hours, :estimated_hours].each{|prop|
        if change[prop].size == 0
          change.delete(prop)
        else
          change[prop] = change[prop].compact.sum
        end
      }

      if change[:sprint].size != 0 && current[:sprint] != change[:sprint][0]
        full_journal[date] ||= {}
        full_journal[date][:sprint] = {:old => current[:sprint], :new => change[:sprint][0]}
      end
      if change.include?(:estimated_hours) && current[:estimated_hours] != change[:estimated_hours]
        full_journal[date] ||= {}
        full_journal[date][:estimated_hours] = {:old => current[:estimated_hours], :new => change[:estimated_hours]}
      end
      if change.include?(:remaining_hours) && current[:remaining_hours] != change[:remaining_hours]
        full_journal[date] ||= {}
        full_journal[date][:remaining_hours] = {:old => current[:remaining_hours], :new => change[:remaining_hours]}
      end
    }
    # End of child journal picking

    # process combined journal in order of timestamp
    full_journal.keys.sort.collect{|date| {:date => date, :update => full_journal[date]} }.each {|entry|
      if entry[:date] != rb.history[-1][:date]
        rb.history << rb.history[-1].dup
        rb.history[-1][:date] = entry[:date]
      end

      entry[:update].each_pair{|prop, old_new|
        rb.history[0][prop] = old_new[:old] if old_new.include?(:old) && !rb.history[0].include?(prop)
        rb.history[-1][prop] = old_new[:new]
        rb.history.each{|h| h[prop] = old_new[:new] unless h.include?(prop) }
      }
    }

    # fill out journal so each journal entry is complete on each day
    rb.history.each{|h|
      h[:estimated_hours] = issue.estimated_hours             unless h.include?(:estimated_hours)
      h[:story_points] = issue.story_points                   unless h.include?(:story_points)
      h[:remaining_hours] = issue.remaining_hours             unless h.include?(:remaining_hours)
      h[:tracker] = RbIssueHistory.issue_type(issue.tracker_id)              unless h.include?(:tracker)
      h[:sprint] = issue.fixed_version_id                     unless h.include?(:sprint)
      h[:status_open] = status[issue.status_id][:open]        unless h.include?(:status_open)
      h[:status_success] = status[issue.status_id][:success]  unless h.include?(:status_success)

      h[:hours] = h[:remaining_hours] || h[:estimated_hours]
    }
    rb.history[-1][:hours] = rb.history[-1][:remaining_hours] || rb.history[-1][:estimated_hours]
    rb.history[0][:hours] = rb.history[0][:estimated_hours] || rb.history[0][:remaining_hours]

    rb.save

    if rb.history.detect{|h| h[:tracker] == :story }
      rb.history.collect{|h| h[:sprint] }.compact.uniq.each{|sprint_id|
        RbSprintBurndown.find_or_initialize_by_version_id(sprint_id).touch!(issue.id)
      }
    end
  end

  def self.rebuild
    self.delete_all
    RbSprintBurndown.delete_all

    status = self.statuses

    issues = Issue.count
    Issue.find(:all, :order => 'root_id asc, lft desc').each_with_index{|issue, n|
      puts "#{issue.id.to_s.rjust(6, ' ')} (#{(n+1).to_s.rjust(6, ' ')}/#{issues})..."
      RbIssueHistory.rebuild_issue(issue, status)
    }
  end

  private

  def set_default_history
    self.history ||= []

    if !issue.new_record? && Time.now < issue.created_on || (self.history.size > 0 && (Date.today < self.history[-1][:date] || Date.today <= self.history[0][:date]))# timecop artifact
      raise "Goodbye time traveller"
      return
    end

    _statuses ||= self.class.statuses
    current = {
      :estimated_hours => self.issue.estimated_hours,
      :story_points => self.issue.story_points,
      :remaining_hours => self.issue.remaining_hours,
      :tracker => RbIssueHistory.issue_type(self.issue.tracker_id),
      :sprint => self.issue.fixed_version_id,
      :status_id => self.issue.status_id,
      :status_open => _statuses[self.issue.status_id][:open],
      :status_success => _statuses[self.issue.status_id][:success],
      :origin => :default
    }
    [[Date.today - 1, lambda{|this, date| this.history.size == 0}], [Date.today, lambda{|this, date| this.history[-1][:date] != date}]].each{|action|
      date, test = *action
      next unless test.call(self, date)

      self.history << {:date => date}.merge(current)
      self.history[-1][:hours] = self.history[-1][:remaining_hours] || self.history[-1][:estimated_hours]
    }
    self.history[-1].merge!(current)
    self.history[-1][:hours] = self.history[-1][:remaining_hours] || self.history[-1][:estimated_hours]
    self.history[0][:hours] = self.history[0][:estimated_hours] || self.history[0][:remaining_hours]
  end

  def touch_sprint
    RbSprintBurndown.find_or_initialize_by_version_id(self.history[-1][:sprint]).touch!(self.issue.id) if self.history[-1][:sprint] && self.history[-1][:tracker] == :story
  end
end
