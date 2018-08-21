################################################################################################
# 
# Copyright 2008, Jovoto GmbH, tassmann@jovoto.com
# Copyright 2006, Original Developed by Rain City Software, darryl.west@RainCitySoftware.com
# version 0.3.0
#
# License: Apache 2.0
#
# Usage:
#   class MyClass << ActiveRecord::Base
#     has_flags [ :symbol, position, true/false, :symbol, ... ], [ options ]
#   end
# Options:
#   :column = 'bit_flags'
#   :group => "group_name" , 
#
# Attribute Accessors:
#   readers: name, name?
#   writer: name=(v)
#   where 'name' is the name of the bit field.  the (v) parameter can be true/false, "true"/"false", 0/1, 'yes'/'no',
#   or :yes/:no.  specifically, the following (v) in   evaluate to true:
#     [ true, 'true', 'yes', :yes, 'ok', :ok, 1, '1' ]
#   all others, including nil evaluate false.
#   groups_name = [Array of flags] , not the plural
#   groups_name << name
#   groups_name 
#   group_ids  
#   group_ids = [Array of flag-ids]
#
#
# Note: db table must include the column 'bit_flags' as an integer. Use the :column option to
#   override with an alternate name
# Note: defaults are set in the 'after_initialized' callback.  If your model needs to use this
#   callback, define it in the class and invoke: init_flags.  Here is an example:
#
#   class MyClass << ActiveRecord::Base
#     has_flags [ :symbol, position, true/false, :symbol, ... ], [ options ]
#     def after_initialize
#       init_flags
#       ... do more stuff ...
#     end
#   end
# 
# Example Use: 
#   has_flags [ :active, true, :has_invoice, 3, :canceled, 8 ]
#     this example creates nine accessor methods, active?, active, active=(v), has_invoice?, has_invoice,
#     has_invoice=(v), canceled?, canceled and canceled=(v).  the 'bit_flags' bit flag is updated to follow 
#     the setters, and when the class is initialized as new (not after a find), the default (active=true) is set.
#
#   has_flags [ :active, true, :deleted 8 ], [ :column = 'status_flags' ]
#   The has_flags method registers the Symbol objects as ? and =(v) accessors.  it also takes care of
#   updating the underlying data element (defaults to 'bit_flags') when the =(v) methods are invoked.  So
#   if MyClass uses has_flags, then you could do the following:
#     myclass = MyClass.new
#     active = false if active?
#     has_invoice = false
#     myclass.save
#   This would change the myclass.bit_flags value, then send it to the database.
#
require 'active_record'

module RainCity
  module Has #:nodoc:
    module BitFlags #:nodoc:
      
      # this hook is called by ActiveRecord::Base
      def self.included(mod)
        mod.extend(ClassMethods)
      end
      
      #
      # declare the class method "has_flags" 
      # create the instance methods based on bitflags and options
      #
      module ClassMethods
        def has_flags(bitflags, options = { })
          unless respond_to? :bitflag_attr
            class_eval { cattr_accessor :bitflag_column, :bitflags, :default_mask, :bitflag_group }
            # use config to lookup these values
            self.bitflag_column, self.bitflags, self.default_mask, self.bitflag_group = 'bit_flags', { }, 0, nil
          end
          
          parse_options options
          create_groupflags if self.bitflag_group
          create_accessors bitflags
          
          # now declare the class Singleton methods
          class_eval { extend RainCity::Has::BitFlags::BitFlagMethods }

          # and the named scopes
          create_named_scopes bitflags
        end
        
        private
        def create_named_scopes(bitflags)
          if (self.bitflag_group)
            scope "by_#{self.bitflag_group}", ->(flag_title) { where(self.flags_conditions(flag_title)) }
          end
          
          
          bitflags.each do |v|
            case v
              when Symbol, String
                flag_title = v.to_s
                scope_name = flag_title
                scope scope_name, ->(arg=nil){ where(self.flags_conditions(flag_title)) }
            end
          end
        end
        
        def create_groupflags
          group   = self.bitflag_group
          groups  = group.pluralize

          define_method(group + "?") do |name|
            self.send(name.to_sym) 
          end

          define_method(group + "=") do |name, value|
            self.send((name.to_s + "=").to_sym,value) 
          end

          define_method( groups ) do
            self.class.flags.collect{|name,id| name }.select{|name| self.send(name.to_sym)}
          end

          define_method(groups + "=") do |names|
            names.map!(&:to_s)
            self.class.flags.each do |name,id|
              self.send((name + "=").to_sym, names.include?(name.to_s))
            end
          end

          define_method(group + "=") do |name|
            self.send((name.to_s + "=").to_sym, true)
          end

          define_method( group + "_ids" ) do
            self.class.flags.select{|name,id| self.send(name.to_sym)}.collect{|array| array[1] }
          end

          define_method(group + "_ids=") do |ids|
            ids.map!(&:to_i)
            self.class.flags.each do |name,id|
              self.send((name + "=").to_sym,ids.include?(id.to_i))
            end
          end
        end

        def create_accessors(bitflags)
          name = nil
          position = 0
          default = false
          column = self.bitflag_column
          bitflags.each do |v|
            case v
              when Symbol, String
                if name
                  add_accessors(column, name, position, default)

                  default = false
                  position += 1
                  #ActiveRecord::Base::scope name.to_s.pluralize, lambda{|c| {:conditions => flags_conditions(name)}} # does not allways work, why?
                end

                name = v.to_s
              when Integer
                position = v
              when TrueClass, FalseClass
                default = v
              else
                raise RuntimeError, "BitFlag: initialize error: " + bitflags.inspect
            end
          end
          # now do the last one
          add_accessors(column, name, position, default)
          
          define_method( 'initialize_flags') do
            if @new_record
              self[column] = self.default_mask
            end
          end
          
          if true
            self.after_initialize :initialize_flags
           # define_method( 'after_initialize' ) do
           #   initialize_flags
           # end
          end
        end
        
        #
        # add the ? and = accessors.  add the after_initialize method unless it's optioned out (:after_init => false)
        #
        def add_accessors(column, name, position, default)
          mask = (1 << position)
          self.bitflags[name] = mask
          if default 
            self.default_mask += mask
          end
          
          # now the instance accessors
          # return true/false
          define_method( (name + '?').to_sym ) do
            bits = self[column] ||= 0
            bits[position].eql? 1
          end
          
          # set with true/false 
          define_method( (name + '=').to_sym ) do |v|
            bits = self[column] ||= 0
            flag = [ "true", '1', 'yes', 'ok' ].include? v.to_s.downcase
            self[column] = flag ? bits |= mask : bits &= ~mask
          end
          
          # make this easy for the form builders like 'check_box' to use standard accessors
          define_method( name.to_sym ) do
            bits = self[column] ||= 0
            bits[position].eql? 1
          end
        
        end
        
        # parse the options for known symbols.  raise a Runtime if a symbol is unrecognized
        def parse_options(options)
          options.each do |opt, val|
            #option.each do |opt, val|
              case opt
                when :column
                  self.bitflag_column = val.to_s
                when :group
                  self.bitflag_group = val.to_s
                  #raise RuntimeError, 'Groups not supported for alpha version...'
                else
                  raise RuntimeError, "BitFlag: unrecognized option: #{opt.class} #{options.class}" + opt.to_s
              end
            #end
          end
        end

      end
      
      # static Singletons
      module BitFlagMethods
        #
        # return the flags as a hash of labels and values, i.e., the symbols (as strings) and bit mask values
        #
        def flags
          self.bitflags
        end
        
        #
        # return the integer mask given the list of defined symbols.
        #
        def mask(*args)
          flags = self.flags
          
          args.inject(0) do |n, name|
            n += flags[name.to_s]
          end
        end
        
        #
        # return the list of objects using the defined symbols as bit arguments
        #
        def find_by_flags(*args)
          conditions = self.flags_conditions(args)
          where([ conditions ])
        end

        def flags_conditions(*args)
          flags = self.flags    
          msk = args.inject(0) do |n, name|
            n += flags[name.to_s]
          end
          s = sprintf "(%s.%s & %i)=%i",self.table_name, self.bitflag_column, msk, msk
        end
      end
    end
  end
end

ActiveRecord::Base.class_eval do
  include RainCity::Has::BitFlags
end
