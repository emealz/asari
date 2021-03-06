require "asari/version"

require "asari/collection"
require "asari/exceptions"
require "asari/geography"
require "asari/document_batch"
require "asari/document"

require "httparty"

require "ostruct"
require "json"
require "cgi"

class Asari
  def self.mode
    @@mode
  end

  def self.mode=(mode)
    @@mode = mode
  end

  attr_writer :api_version
  attr_writer :search_domain
  attr_writer :aws_region

  def initialize(search_domain=nil, aws_region=nil)
    @search_domain = search_domain
    @aws_region = aws_region
  end

  # Public: returns the current search_domain, or raises a
  # MissingSearchDomainException.
  #
  def search_domain
    @search_domain || raise(MissingSearchDomainException.new)
  end

  # Public: returns the current api_version, or the sensible default of
  # "2011-02-01" (at the time of writing, the current version of the
  # CloudSearch API).
  #
  def api_version
    @api_version || "2013-01-01"
  end

  # Public: returns the current aws_region, or the sensible default of
  # "us-east-1."
  def aws_region
    @aws_region || "us-east-1"
  end

  # Public: Search for the specified term.
  #
  # Examples:
  #
  #     @asari.search("fritters") #=> ["13","28"]
  #     @asari.search(filter: { and: { type: 'donuts' }}) #=> ["13,"28","35","50"]
  #     @asari.search("fritters", filter: { and: { type: 'donuts' }}) #=> ["13"]
  #
  # Returns: An Asari::Collection containing all document IDs in the system that match the
  #   specified search term. If no results are found, an empty Asari::Collection is
  #   returned.
  #
  # Raises: SearchException if there's an issue communicating the request to
  #   the server.
  def search(term, options = {})
    return Asari::Collection.sandbox_fake if self.class.mode == :sandbox
    term,options = "",term if term.is_a?(Hash) and options.empty?

    bq = boolean_query(options[:filter]) if options[:filter]
    page_size = options[:page_size].nil? ? 10 : options[:page_size].to_i

    url = "https://search-#{search_domain}.#{aws_region}.cloudsearch.amazonaws.com/#{api_version}/search"

    if options[:filter].present?
      url += "?q=#{CGI.escape(bq)}&q.parser=structured"
    else
      url += "?q=#{CGI.escape(term.to_s)}"
    end

    url += "&size=#{page_size}"
    url += "&q.options=#{CGI.escape(options[:options])}" if options[:options]
    url += "&return=#{options[:return].join ','}" if options[:return]

    if options[:page]
      start = (options[:page].to_i - 1) * page_size
      url << "&start=#{start}"
    end

    if options[:rank]
      rank = normalize_rank(options[:rank])
      url << "&rank=#{rank}"
    end

    begin
      response = HTTParty.get(url)
    rescue Exception => e
      ae = Asari::SearchException.new("#{e.class}: #{e.message} (#{url})")
      ae.set_backtrace e.backtrace
      raise ae
    end

    unless response.response.code == "200"
      raise Asari::SearchException.new("#{response.response.code}: #{response.response.msg} (#{url})")
    end

    Asari::Collection.new(response, page_size)
  end

  # Public: Add an item to the index with the given ID.
  #
  #     obj - the object to associate with this document
  #     fields - a hash of the data to associate with this document. This
  #       needs to match the search fields defined in your CloudSearch domain.
  #
  # Examples:
  #
  #     @asari.add_item(<#>, { :name => "Party Pooper", :email => ..., ... }) #=> nil
  #
  # Returns: nil if the request is successful.
  #
  # Raises: DocumentUpdateException if there's an issue communicating the
  #   request to the server.
  #
  def add_item(obj, fields)
    return nil if self.class.mode == :sandbox
    query = { "type" => "add", "id" => obj.id.to_s, "version" => Time.now.to_i, "lang" => "en" }

    fields.each do |k,v|
      fields[k] = convert_date_or_time(fields[k])
      fields[k] = "" if v.nil?
    end

    query["fields"] = fields
    doc_request(query, obj)
  end

  # Public: Update an item in the index based on its document object.
  #   Note: As of right now, this is the same method call in CloudSearch
  #   that's utilized for adding items. This method is here to provide a
  #   consistent interface in case that changes.
  #
  # Examples:
  #
  #     @asari.update_item(<#>, { :name => "Party Pooper", :email => ..., ... }) #=> nil
  #
  # Returns: nil if the request is successful.
  #
  # Raises: DocumentUpdateException if there's an issue communicating the
  #   request to the server.
  #
  def update_item(obj, fields)
    add_item(obj, fields)
  end

  # Public: Remove an item from the index based on its document object.
  #
  # Examples:
  #
  #     @asari.search("fritters") #=> ["13","28"]
  #     @asari.remove_item("13") #=> nil
  #     @asari.search("fritters") #=> ["28"]
  #     @asari.remove_item("13") #=> nil
  #
  # Returns: nil if the request is successful (note that asking the index to
  #   delete an item that's not present in the index is still a successful
  #   request).
  # Raises: DocumentUpdateException if there's an issue communicating the
  #   request to the server.
  def remove_item(obj)
    return nil if self.class.mode == :sandbox

    query = { "type" => "delete", "id" => obj.id.to_s, "version" => Time.now.to_i }
    doc_request(query)
  end

  # Internal: helper method: common logic for queries against the doc endpoint.
  #
  def doc_request(query, obj = nil)
    endpoint = "http://doc-#{search_domain}.#{aws_region}.cloudsearch.amazonaws.com/#{api_version}/documents/batch"

    options = { :body => [query].to_json, :headers => { "Content-Type" => "application/json"} }

    begin
      response = HTTParty.post(endpoint, options)
    rescue Exception => e
      ae = Asari::DocumentUpdateException.new("#{e.class}: #{e.message}")
      ae.set_backtrace e.backtrace
      raise ae
    end

    if response.response.code == "200"
      obj.send(:update_cloud_search_timestamps) if obj.present?
    else
      puts response
      raise Asari::DocumentUpdateException.new("#{response.response.code}: #{response.response.msg}")
    end

    nil
  end

  def doc_batch(batch)
    url = "http://doc-#{search_domain}.#{aws_region}.cloudsearch.amazonaws.com/#{api_version}/documents/batch"
    response = HTTParty.post(url, body: batch.to_json, headers: { 'Content-Type' => 'application/json' })

    if response.present? && response.body.present?
      parsed_body = JSON.parse(response.body).symbolize_keys!
      raise(Exception, "AwsCloudSearchCloud::DocumentService batch returned #{parsed_body[:errors].size} errors: #{parsed_body}") if parsed_body[:status] == 'error'
    end

    response.body
  end

  protected

  # Private: Builds the query from a passed hash
  #
  #     terms - a hash of the search query. %w(and or not) are reserved hash keys
  #             that build the logic of the query
  def boolean_query(terms = {}, options = {})
    reduce = lambda { |hash|
      hash.reduce("") do |memo, (key, value)|
        if %w(and or not).include?(key.to_s) && value.is_a?(Hash)
          if key.to_s == "and"
            sub_query = reduce.call(value)
            memo += "(#{key}#{sub_query})" unless sub_query.empty?
          elsif key.to_s == "or"
            value.each do |k, v|
              memo += "(#{key} #{v.collect {|e| "'" + e + "'" }.join(" ")})"
            end
          end
        else
          if value.is_a?(Range) || value.is_a?(Integer)
            memo += " (term field=#{key} #{value})"
          else
            if value.is_a?(Array)
              memo += " (range field=#{key} #{value})" unless value.empty?
            else
              memo += " #{key}:'#{value}'" unless value.empty?
            end
          end
        end

        memo
      end
    }
    reduce.call(terms)
  end

  def normalize_rank(rank)
    rank = Array(rank)
    rank << :asc if rank.size < 2
    rank[1] == :desc ? "-#{rank[0]}" : rank[0]
  end

  def convert_date_or_time(obj)
    return obj unless [Time, Date, DateTime].include?(obj.class)
    obj.to_time.to_i
  end
end

Asari.mode = :sandbox # default to sandbox
