Why the changes?
----------------
ActiveRecord JDBC appears to rely on the JDBC Metadata object to get information about a database. This is a pretty good pattern, and is a great thing about JDBC in that it tries to standardize an interface. Unfortunately, for Postgres, the metadata is pretty heinously bad in terms of performance. Don't get me wrong; the Postgres JDBC driver itself is very reliable and performant. And for most applications in Javaland this doesn't matter; you're explicitly typing things etc. But ActiveRecord wants to try to get this metadata so that it can make all the magic for you work. 
###Problem 1 - Types
Firstly, the getTypeInfo() method (on DatabaseMetaData) falls all the way through to AbstractJdbc2DatabaseMetaData in Postgres. Look at this method and you'll see 
`sql = "SELECT t.typname,t.oid FROM pg_catalog.pg_type t"
	+ " JOIN pg_catalog.pg_namespace n ON (t.typnamespace = n.oid) "
	+ " WHERE n.nspname != 'pg_toast' "
	+ " AND typelem = 0 AND typrelid = 0";`
It then takes each row from this resultset and does an additional query to get information about this type, and then map it to the JDBC SQL types. This is an N+1 situation that for 90% of all Rails apps won't matter. Except the Postgres documentation clearly states that tables, views, triggers, etc get composite types that are in this table. So while this returns reasonably on a fresh database, a big fat production database with 5k+ rows will take in excess of *5* minutes. This is really not acceptable, even if this is only done on startup.
###Solution 1 - Static
Many AR adapters appear to follow a simple convention of a NATIVE_DATABASE_TYPES constant that defines all the primitive types. While this may not allow some of the crazy user defined types...that's why you're using an OR/M right? In this case, I just followed this pattern, and overrode set_native_database_types method on the PostgresJdbcConnection and set the variable to the constant. I just dumped the list as the driver returned it and it could be trimmed, but these should all be standard PG types.
###Problem 2 - Columns
Again, we have a pretty inefficient call from the Metadata class here. If you look at the method in the same class as above, you will observe that it does a lot of LEFT JOIN action. In addition, after retrieving the columns, it does additional typing lookups, which are again more expensive than they ought to be, but not as important overall. What does matter is that if the column calls add 3-4s to a retrieve before the column results are cached, then that means hitting a page with say, 6-7 or more AR models may now take quite a while to load. Also consider that in in development mode, Rails will reload your models. This makes for a painful development experience.
###Solution 2 - Rip off postgres_adapter
This is more interesting as it ultimately gets called not only from the Adapter, but from the Connection as well. So I brought over the much more efficient queries and Column creation from the (MRI) postgres_adapter, and since they are used in multiple places, pushed them to a module which I included in both places. For me, this cut a 6s model load time to about .7s and a *30s* load time to about 1.8s. The thing to note here is that the 30s load is one that has an include as part of it's default scope, but is also a legacy table that contains more columns than any table should reasonably have. The JDBC adapter's metadata call definitely degrades as the number of columns decreases. Again, this is an issue that probably would not manifest during greenfield projects.
###Problem 3 - Tables
This is essentially the same as the column situation, although less pronounced. 
###Solution 3 - Same
Once I had moved columns to a module, bringing over the one method was easy enough.

I realize this may not be suitable for everyone, but I need it for acceptable JRuby performance in my application. You can ping me at athemeus@athemeus.com @sharkticon_food on twitters, and jcalvert@vetstreet.com for the professional angle.