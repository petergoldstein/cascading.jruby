# -*- coding: utf-8 -*-
# Copyright 2009, Grégoire Marabout. All Rights Reserved.
#
# This is free software. Please see the LICENSE and COPYING files for details.

require 'cascading/assembly'

module Cascading
  class Flow < Cascading::Node
    extend Registerable

    attr_accessor :properties, :sources, :sinks, :incoming_scopes, :outgoing_scopes, :listeners
    attr_reader :mode

    # Builds a flow given a name and a parent node (a cascade or nil).
    # Optionally accepts a :mode which will determine the execution mode of
    # this flow.  See Cascading::Mode.parse for details.
    def initialize(name, parent, params = {})
      @properties, @sources, @sinks, @incoming_scopes, @outgoing_scopes, @listeners = {}, {}, {}, {}, {}, []
      @mode = Mode.parse(params[:mode])
      @flow_scope = Scope.flow_scope(name)
      super(name, parent)
      self.class.add(name, self)
    end

    def assembly(name, &block)
      raise "Could not build assembly '#{name}'; block required" unless block_given?
      assembly = Assembly.new(name, self, @outgoing_scopes)
      add_child(assembly)
      assembly.instance_eval(&block)
      assembly
    end

    # Create a new source for this flow, using the specified name and
    # Cascading::Tap
    def source(name, tap)
      sources[name] = tap
      incoming_scopes[name] = Scope.source_scope(name, mode.source_tap(name, tap), @flow_scope)
      outgoing_scopes[name] = incoming_scopes[name]
    end

    # Create a new sink for this flow, using the specified name and
    # Cascading::Tap
    def sink(name, tap)
      sinks[name] = tap
    end

    def describe(offset = '')
      description =  "#{offset}#{name}:flow\n"
      description += "#{sources.keys.map{ |source| "#{offset}  #{source}:source :: #{incoming_scopes[source].values_fields.to_a.inspect}" }.join("\n")}\n"
      description += "#{child_names.map{ |child| children[child].describe("#{offset}  ") }.join("\n")}\n"
      description += "#{sinks.keys.map{ |sink| "#{offset}  #{sink}:sink :: #{outgoing_scopes[sink].values_fields.to_a.inspect}" }.join("\n")}"
      description
    end

    def scope(name = nil)
      raise 'Must specify name if no children have been defined yet' unless name || last_child
      name ||= last_child.name
      @outgoing_scopes[name]
    end

    def debug_scope(name = nil)
      scope = scope(name)
      name ||= last_child.name
      puts "Scope for '#{name}':\n  #{scope}"
    end

    def sink_metadata
      @sinks.keys.inject({}) do |sink_metadata, sink_name|
        raise "Cannot sink undefined assembly '#{sink_name}'" unless @outgoing_scopes[sink_name]
        sink_metadata[sink_name] = {
          :field_names => @outgoing_scopes[sink_name].values_fields.to_a,
        }
        sink_metadata
      end
    end

    # TODO: support all codecs, support list of codecs
    def compress_output(codec, type)
      properties['mapred.output.compress'] = 'true'
      properties['mapred.output.compression.codec'] = case codec
        when :default then Java::OrgApacheHadoopIoCompress::DefaultCodec.java_class.name
        when :gzip then Java::OrgApacheHadoopIoCompress::GzipCodec.java_class.name
        else raise "Codec #{codec} not yet supported by cascading.jruby"
        end
      properties['mapred.output.compression.type'] = case type
        when :none   then Java::OrgApacheHadoopIo::SequenceFile::CompressionType::NONE.to_s
        when :record then Java::OrgApacheHadoopIo::SequenceFile::CompressionType::RECORD.to_s
        when :block  then Java::OrgApacheHadoopIo::SequenceFile::CompressionType::BLOCK.to_s
        else raise "Compression type '#{type}' not supported"
        end
    end

    def set_spill_threshold(threshold)
      properties['cascading.cogroup.spill.threshold'] = threshold.to_s
    end

    def add_file_to_distributed_cache(file)
      add_to_distributed_cache(file, "mapred.cache.files")
    end

    def add_archive_to_distributed_cache(file)
      add_to_distributed_cache(file, "mapred.cache.archives")
    end

    def add_listener(listener)
      @listeners << listener
    end

    def emr_local_path_for_distributed_cache_file(file)
      # NOTE this needs to be *appended* to the property mapred.local.dir
      if file =~ /^s3n?:\/\//
        # EMR
        "/taskTracker/archive/#{file.gsub(/^s3n?:\/\//, "")}"
      else
        # Local
        file
      end
    end

    def add_to_distributed_cache(file, property)
      v = properties[property]

      if v
        properties[property] = [v.split(/,/), file].flatten.join(",")
      else
        properties[property] = file
      end
    end

    def connect(properties = nil)
      # This ensures we have a hash, and that it is a Ruby Hash (because we
      # also accept java.util.HashMap), then merges it with Flow properties
      properties ||= {}
      properties = java.util.HashMap.new(@properties.merge(Hash[*properties.to_a.flatten]))

      puts "Connecting flow '#{name}' with properties:"
      properties.key_set.to_a.sort.each do |key|
        puts "#{key}=#{properties[key]}"
      end

      # FIXME: why do I have to do this in 2.0 wip-255?
      Java::CascadingProperty::AppProps.setApplicationName(properties, name)
      Java::CascadingProperty::AppProps.setApplicationVersion(properties, '0.0.0')

      sources = make_tap_parameter(@sources, :head_pipe)
      sinks = make_tap_parameter(@sinks, :tail_pipe)
      pipes = make_pipes
      mode.connect_flow(properties, name, sources, sinks, pipes)
    end

    def complete(properties = nil)
      begin
        flow = connect(properties)
        @listeners.each { |l| flow.addListener(l) }
        flow.complete
      rescue NativeException => e
        raise CascadingException.new(e, 'Error completing flow')
      end
    end

    private

    def make_tap_parameter(taps, pipe_accessor)
      taps.inject({}) do |map, (name, tap)|
        assembly = find_child(name)
        raise "Could not find assembly '#{name}' to connect to tap: #{tap}" unless assembly
        map[assembly.send(pipe_accessor).name] = tap
        map
      end
    end

    def make_pipes
      @sinks.inject([]) do |pipes, (name, sink)|
        assembly = find_child(name)
        raise "Could not find assembly '#{name}' to make pipe for sink: #{sink}" unless assembly
        pipes << assembly.tail_pipe
        pipes
      end.to_java(Java::CascadingPipe::Pipe)
    end
  end
end
