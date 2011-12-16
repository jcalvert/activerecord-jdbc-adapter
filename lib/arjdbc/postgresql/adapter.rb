module ActiveRecord::ConnectionAdapters
  PostgreSQLAdapter = Class.new(AbstractAdapter) unless const_defined?(:PostgreSQLAdapter)
  
  module Utilities
    # Returns the list of a table's column names, data types, and default values.
     #
     # The underlying query is roughly:
     #  SELECT column.name, column.type, default.value
     #    FROM column LEFT JOIN default
     #      ON column.table_id = default.table_id
     #     AND column.num = default.column_num
     #   WHERE column.table_id = get_table_id('table_name')
     #     AND column.num > 0
     #     AND NOT column.is_dropped
     #   ORDER BY column.num
     #
     # If the table name is not prefixed with a schema, the database will
     # take the first match from the schema search path.
     #
     # Query implementation notes:
     #  - format_type includes the column size constraint, e.g. varchar(50)
     #  - ::regclass is a function that gives the id for a table name
     def column_definitions(table_name) #:nodoc:
       query <<-end_sql
         SELECT a.attname, d.adsrc, format_type(a.atttypid, a.atttypmod), a.attnotnull
           FROM pg_attribute a LEFT JOIN pg_attrdef d
             ON a.attrelid = d.adrelid AND a.attnum = d.adnum
          WHERE a.attrelid = '#{quote_table_name(table_name)}'::regclass
            AND a.attnum > 0 AND NOT a.attisdropped
          ORDER BY a.attnum
       end_sql
     end
      
     def query(sql, name = nil) #feels a bit icky, but you need all this stuff in two places? 
         (!@connection.nil? && (@connection.respond_to? :execute) ? @connection : self).execute(sql).collect{|res| res.values}   
     end
    
    def pg_columns_inner(table_name, name=nil)
      column_definitions(table_name).collect do |name, default, type, notnull|
        ActiveRecord::ConnectionAdapters::PostgreSQLColumn.new(name, default, type, notnull == 'f')
      end
    end
    
    
    # Returns the list of all tables in the schema search path or a specified schema.
    def tables(name = nil)
       query(<<-SQL, name).map { |row| row[0] }
         SELECT tablename
         FROM pg_tables
         WHERE schemaname = ANY (current_schemas(false))
       SQL
    end
    
    def extract_pg_identifier_from_name(name)
       match_data = name[0,1] == '"' ? name.match(/\"([^\"]+)\"/) : name.match(/([^\.]+)/)

       if match_data
         rest = name[match_data[0].length..-1]
         rest = rest[1..-1] if rest[0,1] == "."
         [match_data[1], (rest.length > 0 ? rest : nil)]
       end
     end
   
     def quote_table_name(name)
       schema, name_part = extract_pg_identifier_from_name(name.to_s)
       unless name_part
         quote_column_name(schema)
       else
         table_name, name_part = extract_pg_identifier_from_name(name_part)
         "#{quote_column_name(schema)}.#{quote_column_name(table_name)}"
       end
     end

     def quote_column_name(name)
       %("#{name.to_s.gsub("\"", "\"\"")}")
     end
  end
end

module ::ArJdbc
  module PostgreSQL
    include ActiveRecord::ConnectionAdapters::Utilities
    def self.extended(mod)
      (class << mod; self; end).class_eval do
        alias_chained_method :insert, :query_dirty, :pg_insert
        alias_chained_method :columns, :query_cache, :pg_columns
      end
    end

    def self.column_selector
      [/postgre/i, lambda {|cfg,col| col.extend(::ArJdbc::PostgreSQL::Column)}]
    end

    def self.jdbc_connection_class
      ::ActiveRecord::ConnectionAdapters::PostgresJdbcConnection
    end

    module Column
      def type_cast(value)
        case type
        when :boolean then cast_to_boolean(value)
        else super
        end
      end

      def extract_limit(sql_type)
        case sql_type
        when /^int2/i;      2
        when /^smallint/i;  2
        when /^int4/i;      nil
        when /^integer/i;   nil
        when /^int8/i;      8
        when /^bigint/i;    8
        when /^(bool|text|date|time|bytea)/i; nil # ACTIVERECORD_JDBC-135,139
        else super
        end
      end

      def simplified_type(field_type)
        return :integer if field_type =~ /^(big|)serial/i
        return :string if field_type =~ /\[\]$/i || field_type =~ /^interval/i
        return :string if field_type =~ /^(?:point|lseg|box|"?path"?|polygon|circle)/i
        return :string if field_type =~ /^uuid/i
        return :datetime if field_type =~ /^timestamp/i
        return :float if field_type =~ /^(?:real|double precision)$/i
        return :binary if field_type =~ /^bytea/i
        return :boolean if field_type =~ /^bool/i
        return :decimal if field_type == 'numeric(131089)'
        super
      end

      def cast_to_boolean(value)
        return nil if value.nil?
        if value == true || value == false
          value
        else
          %w(true t 1).include?(value.to_s.downcase)
        end
      end

      # Post process default value from JDBC into a Rails-friendly format (columns{-internal})
      def default_value(value)
        # Boolean types
        return "t" if value =~ /true/i
        return "f" if value =~ /false/i

        # Char/String/Bytea type values
        return $1 if value =~ /^'(.*)'::(bpchar|text|character varying|bytea)$/

        # Numeric values
        return value.delete("()") if value =~ /^\(?-?[0-9]+(\.[0-9]*)?\)?/

        # Fixed dates / timestamp
        return $1 if value =~ /^'(.+)'::(date|timestamp)/

        # Anything else is blank, some user type, or some function
        # and we can't know the value of that, so return nil.
        return nil
      end
    end

    def modify_types(tp)
      tp[:primary_key] = "serial primary key"
      tp[:string][:limit] = 255
      tp[:integer][:limit] = nil
      tp[:boolean] = { :name => "boolean" }
      tp[:float] = { :name => "float" }
      tp[:text] = { :name => "text" }
      tp[:datetime] = { :name => "timestamp" }
      tp[:timestamp] = { :name => "timestamp" }
      tp[:time] = { :name => "time" }
      tp[:date] = { :name => "date" }
      tp[:decimal] = { :name => "decimal" }
      tp
    end

    def adapter_name #:nodoc:
      'PostgreSQL'
    end


    def self.arel2_visitors(config)
      {}.tap {|v| %w(postgresql pg jdbcpostgresql).each {|a| v[a] = ::Arel::Visitors::PostgreSQL } }
    end

    def postgresql_version
      @postgresql_version ||=
        begin
          value = select_value('SELECT version()')
          if value =~ /PostgreSQL (\d+)\.(\d+)\.(\d+)/
            ($1.to_i * 10000) + ($2.to_i * 100) + $3.to_i
          else
            0
          end
        end
    end

    # Does PostgreSQL support migrations?
    def supports_migrations?
      true
    end

    # Does PostgreSQL support standard conforming strings?
    def supports_standard_conforming_strings?
      # Temporarily set the client message level above error to prevent unintentional
      # error messages in the logs when working on a PostgreSQL database server that
      # does not support standard conforming strings.
      client_min_messages_old = client_min_messages
      self.client_min_messages = 'panic'

      # postgres-pr does not raise an exception when client_min_messages is set higher
      # than error and "SHOW standard_conforming_strings" fails, but returns an empty
      # PGresult instead.
      has_support = select('SHOW standard_conforming_strings').to_a[0][0] rescue false
      self.client_min_messages = client_min_messages_old
      has_support
    end

    def supports_insert_with_returning?
      postgresql_version >= 80200
    end

    def supports_ddl_transactions?
      true
    end

    def supports_savepoints?
      true
    end

    def supports_count_distinct? #:nodoc:
      false
    end

    def create_savepoint
      execute("SAVEPOINT #{current_savepoint_name}")
    end

    def rollback_to_savepoint
      execute("ROLLBACK TO SAVEPOINT #{current_savepoint_name}")
    end

    def release_savepoint
      execute("RELEASE SAVEPOINT #{current_savepoint_name}")
    end

    # Returns the configured supported identifier length supported by PostgreSQL,
    # or report the default of 63 on PostgreSQL 7.x.
    def table_alias_length
      @table_alias_length ||= (postgresql_version >= 80000 ? select_one('SHOW max_identifier_length')['max_identifier_length'].to_i : 63)
    end

    def default_sequence_name(table_name, pk = nil)
      default_pk, default_seq = pk_and_sequence_for(table_name)
      default_seq || "#{table_name}_#{pk || default_pk || 'id'}_seq"
    end

    # Resets sequence to the max value of the table's pk if present.
    def reset_pk_sequence!(table, pk = nil, sequence = nil) #:nodoc:
      unless pk and sequence
        default_pk, default_sequence = pk_and_sequence_for(table)
        pk ||= default_pk
        sequence ||= default_sequence
      end
      if pk
        if sequence
          quoted_sequence = quote_column_name(sequence)

          select_value <<-end_sql, 'Reset sequence'
              SELECT setval('#{quoted_sequence}', (SELECT COALESCE(MAX(#{quote_column_name pk})+(SELECT increment_by FROM #{quoted_sequence}), (SELECT min_value FROM #{quoted_sequence})) FROM #{quote_table_name(table)}), false)
            end_sql
        else
          @logger.warn "#{table} has primary key #{pk} with no default sequence" if @logger
        end
      end
    end

    # Find a table's primary key and sequence.
    def pk_and_sequence_for(table) #:nodoc:
      # First try looking for a sequence with a dependency on the
      # given table's primary key.
      result = select(<<-end_sql, 'PK and serial sequence')[0]
          SELECT attr.attname, seq.relname
          FROM pg_class      seq,
               pg_attribute  attr,
               pg_depend     dep,
               pg_namespace  name,
               pg_constraint cons
          WHERE seq.oid           = dep.objid
            AND seq.relkind       = 'S'
            AND attr.attrelid     = dep.refobjid
            AND attr.attnum       = dep.refobjsubid
            AND attr.attrelid     = cons.conrelid
            AND attr.attnum       = cons.conkey[1]
            AND cons.contype      = 'p'
            AND dep.refobjid      = '#{quote_table_name(table)}'::regclass
        end_sql

      if result.nil? or result.empty?
        # If that fails, try parsing the primary key's default value.
        # Support the 7.x and 8.0 nextval('foo'::text) as well as
        # the 8.1+ nextval('foo'::regclass).
        result = select(<<-end_sql, 'PK and custom sequence')[0]
            SELECT attr.attname,
              CASE
                WHEN split_part(def.adsrc, '''', 2) ~ '.' THEN
                  substr(split_part(def.adsrc, '''', 2),
                         strpos(split_part(def.adsrc, '''', 2), '.')+1)
                ELSE split_part(def.adsrc, '''', 2)
              END as relname
            FROM pg_class       t
            JOIN pg_attribute   attr ON (t.oid = attrelid)
            JOIN pg_attrdef     def  ON (adrelid = attrelid AND adnum = attnum)
            JOIN pg_constraint  cons ON (conrelid = adrelid AND adnum = conkey[1])
            WHERE t.oid = '#{quote_table_name(table)}'::regclass
              AND cons.contype = 'p'
              AND def.adsrc ~* 'nextval'
          end_sql
      end

      [result["attname"], result["relname"]]
    rescue
      nil
    end

    def pg_insert(sql, name = nil, pk = nil, id_value = nil, sequence_name = nil, binds = [])
      sql = substitute_binds(sql, binds)

      # Extract the table from the insert sql. Yuck.
      table = sql.split(" ", 4)[2].gsub('"', '')

      # Try an insert with 'returning id' if available (PG >= 8.2)
      if supports_insert_with_returning? && id_value.nil?
        pk, sequence_name = *pk_and_sequence_for(table) unless pk
        if pk
          sql = substitute_binds(sql, binds)
          id_value = select_value("#{sql} RETURNING #{quote_column_name(pk)}")
          clear_query_cache #FIXME: Why now?
          return id_value
        end
      end

      # Otherwise, plain insert
      execute(sql, name, binds)

      # Don't need to look up id_value if we already have it.
      # (and can't in case of non-sequence PK)
      unless id_value
        # If neither pk nor sequence name is given, look them up.
        unless pk || sequence_name
          pk, sequence_name = *pk_and_sequence_for(table)
        end

        # If a pk is given, fallback to default sequence name.
        # Don't fetch last insert id for a table without a pk.
        if pk && sequence_name ||= default_sequence_name(table, pk)
          id_value = last_insert_id(table, sequence_name)
        end
      end
      id_value
    end
   
    def pg_columns(table_name, name=nil)
        pg_columns_inner(table_name, name)
    end
   
    # Sets the maximum number columns postgres has, default 32
    def multi_column_index_limit=(limit)
      @multi_column_index_limit = limit
    end

    # Gets the maximum number columns postgres has, default 32
    def multi_column_index_limit
      defined?(@multi_column_index_limit) && @multi_column_index_limit || 32
    end

    # Based on postgresql_adapter.rb
    def indexes(table_name, name = nil)
      schema_search_path = @config[:schema_search_path] || select_rows('SHOW search_path')[0][0]
      schemas = schema_search_path.split(/,/).map { |p| quote(p) }.join(',')
      result = select_rows(<<-SQL, name)
        SELECT i.relname, d.indisunique, a.attname, a.attnum, d.indkey
          FROM pg_class t, pg_class i, pg_index d, pg_attribute a,
          generate_series(0,#{multi_column_index_limit - 1}) AS s(i)
         WHERE i.relkind = 'i'
           AND d.indexrelid = i.oid
           AND d.indisprimary = 'f'
           AND t.oid = d.indrelid
           AND t.relname = '#{table_name}'
           AND i.relnamespace IN (SELECT oid FROM pg_namespace WHERE nspname IN (#{schemas}) )
           AND a.attrelid = t.oid
           AND d.indkey[s.i]=a.attnum
        ORDER BY i.relname
      SQL

      current_index = nil
      indexes = []

      insertion_order = []
      index_order = nil
      
      result.each do |row|
        if current_index != row[0]
        
          (index_order = row[4].split(' ')).each_with_index{ |v, i| index_order[i] = v.to_i }
          indexes << ::ActiveRecord::ConnectionAdapters::IndexDefinition.new(table_name, row[0], row[1] == "t", [])
          current_index = row[0]
        end
        insertion_order = row[3]
        ind = index_order.index(insertion_order)
        indexes.last.columns[ind] = row[2]
      end

      indexes
    end

    def last_insert_id(table, sequence_name)
      Integer(select_value("SELECT currval('#{sequence_name}')"))
    end

    def recreate_database(name)
      drop_database(name)
      create_database(name)
    end

    def create_database(name, options = {})
      execute "CREATE DATABASE \"#{name}\" ENCODING='#{options[:encoding] || 'utf8'}'"
    end

    def drop_database(name)
      execute "DROP DATABASE IF EXISTS \"#{name}\""
    end

    def create_schema(schema_name, pg_username)
      execute("CREATE SCHEMA \"#{schema_name}\" AUTHORIZATION \"#{pg_username}\"")
    end

    def drop_schema(schema_name)
      execute("DROP SCHEMA \"#{schema_name}\"")
    end

    def all_schemas
      select('select nspname from pg_namespace').map {|r| r["nspname"] }
    end

    def primary_key(table)
      pk_and_sequence = pk_and_sequence_for(table)
      pk_and_sequence && pk_and_sequence.first
    end

    def structure_dump
      database = @config[:database]
      if database.nil?
        if @config[:url] =~ /\/([^\/]*)$/
          database = $1
        else
          raise "Could not figure out what database this url is for #{@config["url"]}"
        end
      end

      ENV['PGHOST']     = @config[:host] if @config[:host]
      ENV['PGPORT']     = @config[:port].to_s if @config[:port]
      ENV['PGPASSWORD'] = @config[:password].to_s if @config[:password]
      search_path = @config[:schema_search_path]
      search_path = "--schema=#{search_path}" if search_path

      @connection.connection.close
      begin
        definition = `pg_dump -i -U "#{@config[:username]}" -s -x -O #{search_path} #{database}`
        raise "Error dumping database" if $?.exitstatus == 1

        # need to patch away any references to SQL_ASCII as it breaks the JDBC driver
        definition.gsub(/SQL_ASCII/, 'UNICODE')
      ensure
        reconnect!
      end
    end

    # SELECT DISTINCT clause for a given set of columns and a given ORDER BY clause.
    #
    # PostgreSQL requires the ORDER BY columns in the select list for distinct queries, and
    # requires that the ORDER BY include the distinct column.
    #
    #   distinct("posts.id", "posts.created_at desc")
    def distinct(columns, order_by)
      return "DISTINCT #{columns}" if order_by.blank?

      # construct a clean list of column names from the ORDER BY clause, removing
      # any asc/desc modifiers
      order_columns = [order_by].flatten.map{|o| o.split(',').collect { |s| s.split.first } }.flatten.reject(&:blank?)
      order_columns = order_columns.zip((0...order_columns.size).to_a).map { |s,i| "#{s} AS alias_#{i}" }

      # return a DISTINCT ON() clause that's distinct on the columns we want but includes
      # all the required columns for the ORDER BY to work properly
      sql = "DISTINCT ON (#{columns}) #{columns}, "
      sql << order_columns * ', '
    end

    # ORDER BY clause for the passed order option.
    #
    # PostgreSQL does not allow arbitrary ordering when using DISTINCT ON, so we work around this
    # by wrapping the sql as a sub-select and ordering in that query.
    def add_order_by_for_association_limiting!(sql, options)
      return sql if options[:order].blank?

      order = options[:order].split(',').collect { |s| s.strip }.reject(&:blank?)
      order.map! { |s| 'DESC' if s =~ /\bdesc$/i }
      order = order.zip((0...order.size).to_a).map { |s,i| "id_list.alias_#{i} #{s}" }.join(', ')

      sql.replace "SELECT * FROM (#{sql}) AS id_list ORDER BY #{order}"
    end

    def quote(value, column = nil) #:nodoc:
      return super unless column

      if value.kind_of?(String) && column.type == :binary
        "E'#{escape_bytea(value)}'"
      elsif value.kind_of?(String) && column.sql_type == 'xml'
        "xml '#{quote_string(value)}'"
      elsif value.kind_of?(Numeric) && column.sql_type == 'money'
        # Not truly string input, so doesn't require (or allow) escape string syntax.
        "'#{value}'"
      elsif value.kind_of?(String) && column.sql_type =~ /^bit/
        case value
        when /^[01]*$/
          "B'#{value}'" # Bit-string notation
        when /^[0-9A-F]*$/i
          "X'#{value}'" # Hexadecimal notation
        end
      else
        super
      end
    end

    def escape_bytea(s)
      if s
        result = ''
        s.each_byte { |c| result << sprintf('\\\\%03o', c) }
        result
      end
    end

    def quoted_date(value) #:nodoc:
      if value.acts_like?(:time) && value.respond_to?(:usec)
        "#{super}.#{sprintf("%06d", value.usec)}"
      else
        super
      end
    end

    def disable_referential_integrity(&block) #:nodoc:
      execute(tables.collect { |name| "ALTER TABLE #{quote_table_name(name)} DISABLE TRIGGER ALL" }.join(";"))
      yield
    ensure
      execute(tables.collect { |name| "ALTER TABLE #{quote_table_name(name)} ENABLE TRIGGER ALL" }.join(";"))
    end

    def rename_table(name, new_name)
      execute "ALTER TABLE #{name} RENAME TO #{new_name}"
    end

    # Adds a new column to the named table.
    # See TableDefinition#column for details of the options you can use.
    def add_column(table_name, column_name, type, options = {})
      default = options[:default]
      notnull = options[:null] == false

      # Add the column.
      execute("ALTER TABLE #{quote_table_name(table_name)} ADD COLUMN #{quote_column_name(column_name)} #{type_to_sql(type, options[:limit], options[:precision], options[:scale])}")

      change_column_default(table_name, column_name, default) if options_include_default?(options)
      change_column_null(table_name, column_name, false, default) if notnull
    end

    # Changes the column of a table.
    def change_column(table_name, column_name, type, options = {})
      quoted_table_name = quote_table_name(table_name)

      begin
        execute "ALTER TABLE #{quoted_table_name} ALTER COLUMN #{quote_column_name(column_name)} TYPE #{type_to_sql(type, options[:limit], options[:precision], options[:scale])}"
      rescue ActiveRecord::StatementInvalid => e
        raise e if postgresql_version > 80000
        # This is PostgreSQL 7.x, so we have to use a more arcane way of doing it.
        begin
          begin_db_transaction
          tmp_column_name = "#{column_name}_ar_tmp"
          add_column(table_name, tmp_column_name, type, options)
          execute "UPDATE #{quoted_table_name} SET #{quote_column_name(tmp_column_name)} = CAST(#{quote_column_name(column_name)} AS #{type_to_sql(type, options[:limit], options[:precision], options[:scale])})"
          remove_column(table_name, column_name)
          rename_column(table_name, tmp_column_name, column_name)
          commit_db_transaction
        rescue
          rollback_db_transaction
        end
      end

      change_column_default(table_name, column_name, options[:default]) if options_include_default?(options)
      change_column_null(table_name, column_name, options[:null], options[:default]) if options.key?(:null)
    end

    # Changes the default value of a table column.
    def change_column_default(table_name, column_name, default)
      execute "ALTER TABLE #{quote_table_name(table_name)} ALTER COLUMN #{quote_column_name(column_name)} SET DEFAULT #{quote(default)}"
    end

    def change_column_null(table_name, column_name, null, default = nil)
      unless null || default.nil?
        execute("UPDATE #{quote_table_name(table_name)} SET #{quote_column_name(column_name)}=#{quote(default)} WHERE #{quote_column_name(column_name)} IS NULL")
      end
      execute("ALTER TABLE #{quote_table_name(table_name)} ALTER #{quote_column_name(column_name)} #{null ? 'DROP' : 'SET'} NOT NULL")
    end

    def rename_column(table_name, column_name, new_column_name) #:nodoc:
      execute "ALTER TABLE #{quote_table_name(table_name)} RENAME COLUMN #{quote_column_name(column_name)} TO #{quote_column_name(new_column_name)}"
    end

    def remove_index(table_name, options) #:nodoc:
      execute "DROP INDEX #{index_name(table_name, options)}"
    end

    def type_to_sql(type, limit = nil, precision = nil, scale = nil) #:nodoc:
      return super unless type.to_s == 'integer'

      if limit.nil? || limit == 4
        'integer'
      elsif limit < 4
        'smallint'
      else
        'bigint'
      end
    end

    private
    def translate_exception(exception, message)
      case exception.message
      when /duplicate key value violates unique constraint/
        ::ActiveRecord::RecordNotUnique.new(message, exception)
      when /violates foreign key constraint/
        ::ActiveRecord::InvalidForeignKey.new(message, exception)
      else
        super
      end
    end

  end
end

module ActiveRecord::ConnectionAdapters
  remove_const(:PostgreSQLAdapter) if const_defined?(:PostgreSQLAdapter)

  class PostgreSQLColumn < JdbcColumn
    include ArJdbc::PostgreSQL::Column

    def initialize(name, *args)
      if Hash === name
        super
      else
        super(nil, name, *args)
      end
    end

    def call_discovered_column_callbacks(*)
    end
  end

  class PostgresJdbcConnection < JdbcConnection
    include ActiveRecord::ConnectionAdapters::Utilities
   
    alias :columns :pg_columns_inner
    alias :columns_internal :pg_columns_inner 
    alias :java_native_database_types :set_native_database_types
    
    NATIVE_DATABASE_TYPES = {
       :bool=>{:name=>"bool"},
       :bytea=>{:name=>"bytea"},
       :char=>{:name=>"char"},
       :int8=>{:name=>"int8"},
       :bigserial=>{:name=>"bigserial"},
       :int2=>{:name=>"int2"},
       :int4=>{:name=>"int4"},
       :serial=>{:name=>"serial"},
       :regproc=>{:name=>"regproc"},
       :text=>{:name=>"text"},
       :oid=>{:name=>"oid"},
       :tid=>{:name=>"tid"},
       :xid=>{:name=>"xid"},
       :cid=>{:name=>"cid"},
       :xml=>{:name=>"xml"},
       :smgr=>{:name=>"smgr"},
       :path=>{:name=>"path"},
       :polygon=>{:name=>"polygon"},
       :float4=>{:name=>"float4"},
       :float8=>{:name=>"float8"},
       :abstime=>{:name=>"abstime"},
       :reltime=>{:name=>"reltime"},
       :tinterval=>{:name=>"tinterval"},
       :unknown=>{:name=>"unknown"},
       :circle=>{:name=>"circle"},
       :money=>{:name=>"money"},
       :macaddr=>{:name=>"macaddr"},
       :inet=>{:name=>"inet"},
       :cidr=>{:name=>"cidr"},
       :aclitem=>{:name=>"aclitem"},
       :bpchar=>{:name=>"bpchar", :limit=>10485760},
       :varchar=>{:name=>"varchar", :limit=>10485760},
       :date=>{:name=>"date"},
       :time=>{:name=>"time"},
       :timestamp=>{:name=>"timestamp"},
       :timestamptz=>{:name=>"timestamptz", :limit=>6},
       :interval=>{:name=>"interval", :limit=>6},
       :timetz=>{:name=>"timetz", :limit=>6},
       :bit=>{:name=>"bit", :limit=>83886080},
       :varbit=>{:name=>"varbit", :limit=>83886080},
       :numeric=>{:name=>"numeric", :limit=>1000},
       :refcursor=>{:name=>"refcursor"},
       :regprocedure=>{:name=>"regprocedure"},
       :regoper=>{:name=>"regoper"},
       :regoperator=>{:name=>"regoperator"},
       :regclass=>{:name=>"regclass"},
       :regtype=>{:name=>"regtype"},
       :uuid=>{:name=>"uuid"},
       :tsvector=>{:name=>"tsvector"},
       :gtsvector=>{:name=>"gtsvector"},
       :tsquery=>{:name=>"tsquery"},
       :regconfig=>{:name=>"regconfig"},
       :regdictionary=>{:name=>"regdictionary"},
       :txid_snapshot=>{:name=>"txid_snapshot"},
       :record=>{:name=>"record"},
       :cstring=>{:name=>"cstring"},
       :any=>{:name=>"any"},
       :anyarray=>{:name=>"anyarray"},
       :void=>{:name=>"void"},
       :trigger=>{:name=>"trigger"},
       :language_handler=>{:name=>"language_handler"},
       :internal=>{:name=>"internal"},
       :opaque=>{:name=>"opaque"},
       :anyelement=>{:name=>"anyelement"},
       :anynonarray=>{:name=>"anynonarray"},
       :anyenum=>{:name=>"anyenum"},
       :cardinal_number=>{:name=>"cardinal_number"},
       :character_data=>{:name=>"character_data"},
       :sql_identifier=>{:name=>"sql_identifier"},
       :time_stamp=>{:name=>"time_stamp"},
       :chkpass=>{:name=>"chkpass"},
       :ghstore=>{:name=>"ghstore"},
       :hstore=>{:name=>"hstore"},
       :intbig_gkey=>{:name=>"intbig_gkey"},
       :query_int=>{:name=>"query_int"},
       :lo=>{:name=>"lo"},
       :email=>{:name=>"email"},
       :string=>{:name=>"varchar", :limit=>10485760},
       :integer=>{:name=>"int4"},
       :decimal=>{:name=>"numeric", :limit=>1000},
       :float=>{:name=>"float4"},
       :datetime=>{:name=>"timestamp"},
       :binary=>{:name=>"bytea"},
       :boolean=>{:name=>"boolean", :limit=>1}
    }
    
    def set_native_database_types
      @native_types = NATIVE_DATABASE_TYPES
    end
  end
  
  class PostgreSQLAdapter < JdbcAdapter
    include ArJdbc::PostgreSQL

    def jdbc_connection_class(spec)
      ::ArJdbc::PostgreSQL.jdbc_connection_class
    end

    def jdbc_column_class
      ActiveRecord::ConnectionAdapters::PostgreSQLColumn
    end
    
    alias_chained_method :insert, :query_dirty, :pg_insert
    alias_chained_method :columns, :query_cache, :pg_columns
  end
end