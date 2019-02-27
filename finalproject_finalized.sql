--examples of importing shapefiles
shp2pgsql -W LATIN1 -s 4269 -I C:\Users\nakam031\Downloads\tl_2017_32_tract\tl_2017_32_tract.shp nv_census_tract | psql -h gis5777.csaba3m4f8xj.us-east-1.rds.amazonaws.com -d nakam031 -p 5432 -U nakam031

shp2pgsql -W LATIN1 -s 4269 -I E:\gis5577\cb_2016_us_ua10_500k\cb_2016_us_ua10_500k.shp 2016_us_urbanarea | psql -h gis5777.csaba3m4f8xj.us-east-1.rds.amazonaws.com -d nakam031 -p 5432 -U nakam031


--examples of cleaning the shapefile
ALTER TABLE IF EXISTS wf_nv_poly_nad83
DROP COLUMN fire_dscvr, DROP COLUMN fire_dsc_2, DROP COLUMN fire_cntrl, DROP COLUMN fire_cnt_1

ALTER TABLE IF EXISTS nv_census_tract
RENAME COLUMN awater TO water_sqm

--create a new table of urban area
CREATE TABLE nv_urbanarea_2016 AS (
SELECT * FROM us_urbanarea_2016 WHERE lower(NAME10) LIKE '%nv%')

--ALTER TABLE name
ALTER TABLE IF EXISTS nv_urbanarea_2016
rename to nv_urbanarea_2010

--create a table WITH separate urban area name and state

CREATE TABLE nv_urbanarea_2010c AS(
WITH urbanarea AS (
SELECT split_part(ua_name,',', 1) AS urban_name, 
	split_part(ua_name,',',2) AS state_name, gid FROM nv_urbanarea_copy)
SELECT u.gid, u.urban_area, c.urban_name, c.state_name, u.affgeoid10, u.geoid10,
	u.area_type, u.land_sqm, u.water_sqm, u.geom
	FROM nv_urbanarea_2010 u
	left join urbanarea c ON (u.gid=c.gid))
	
--create table join_wf by joining point shp and polygon shp 
DROP TABLE IF EXISTS
CREATE TABLE join_wf AS
SELECT py.gid AS py_gid, py.fire_code_ AS py_firecode,
 py.fire_dsc_1 AS py_date, py.fire_cause py_cause,
 py.gis_acres AS py_acres, py.geom AS py_geom,
 pt.gid AS pt_gid, pt.firename AS pt_firename, pt.firecode AS pt_firecode, 
 pt.cause AS pt_cause, pt.sizeclass AS pt_sizeclass, pt.firetype AS pt_type, 
 pt.startdated AS pt_startdate, pt.totalacres AS pt_totacres, pt.geom AS pt_geom
 FROM wf_nv_poly_nad83 py
 INNER JOIN wf_nevada_2000_2016 pt ON (py.fire_code_=pt.firecode)
WHERE py.fire_dsc_1=pt.startdated
--By using join_wf, create a thematic map using class size (Map 1)

--check how many fire locations are reported in each year
--Create a graph FROM the result (graph 1)
SELECT count(date_part('year',pt_startdate)) fire_count, date_part('year',pt_startdate)
FROM join_wf
WHERE date_part('year',pt_startdate)>1999
GROUP BY date_part('year',pt_startdate)
ORDER BY date_part('year',pt_startdate)

--how many fire points reported in each year 
--GROUP BY cause (natural,human) and create a graph FROM the result (graph 2)
SELECT count(pt_cause), pt_cause, date_part('year',pt_startdate)
FROM join_wf
GROUP BY pt_cause, date_part('year',pt_startdate)
ORDER BY pt_cause, date_part('year',pt_startdate)

--total acres burned each year (graph 3)
SELECT sum(pt_totacres) AS wf_areasqkm, 
date_part('year',py_date) AS startyear
FROM join_wf
WHERE date_part('year',py_date)>1999
GROUP BY date_part('year',py_date)
ORDER BY wf_areasqkm DESC

--total acres burned each year by cause (graph4)
SELECT sum(pt_totacres) AS wf_areasqkm, pt_cause,
date_part('year',py_date) AS startyear
FROM join_wf
WHERE date_part('year',py_date)>1999
GROUP BY date_part('year',py_date), pt_cause

--spatial join WITH wildfire locations and census tract
--Create a choropleth map shows wildfire damaged area (sqkm) by census tract (Map 2)
WITH census_tract AS (SELECT c.name AS countyname,
t.geoid AS tract_id, t.countyfp AS county_fp, ST_transform(t.geom,26911) AS tract_geom
FROM nv_census_tract t, us_counties_wgs84 c
WHERE c.statefp = '32' AND t.countyfp = c.countyfp)
SELECT sum(pt_totacres)*0.00404686 AS wf_areasqkm, c.countyname, c.tract_id, c.tract_geom
FROM join_wf j, census_tract c
WHERE ST_intersects(c.tract_geom,ST_transform(j.pt_geom,26911))
GROUP BY c.countyname, c.tract_id, c.tract_geom


/*ERROR*/
--find WHERE in fire polygon and road intersects
SELECT r.name, ST_transform(r.geom,4269), r.feature
FROM roads_wgs84 r, join_wf p
WHERE ST_intersects(p.py_geom,ST_transform(r.geom, 4269))

--finds ring self-intersection error in py_geom
SELECT DISTINCT ST_isvalidreason(py_geom)
FROM join_wf
--googled the possible solutions (1). This did not work
UPDATE join_wf
SET py_geom = ST_SimplifyPreserveTopology(py_geom,0.0001)
WHERE ST_isvalid(py_geom)=false;
--another solutions (2). This worked
update join_wf
SET py_geom=ST_MakeValid(py_geom)

--find WHERE fire polygon and road intersects
WITH nv_road AS (
SELECT * FROM roads_wgs84
WHERE state='NV')
SELECT r.gid, ST_transform(r.geom,26911) geom, p.pt_startdate,r.name
FROM nv_road r, join_wf p
WHERE ST_intersects(ST_transform(p.py_geom,26911),ST_transform(r.geom,26911))

--Use radius 200m fire point buffer to find intersects WITH road
--Also, create a buffer for radius 100m  (Map 3)
WITH nv_road AS (
SELECT * FROM roads_wgs84
WHERE lower(state)='nv'),
point_buffer AS (
SELECT ST_buffer(ST_transform(pt_geom,26911),200) AS buffergeom, pt_sizeclass, pt_startdate
FROM join_wf)
SELECT r.gid, ST_transform(r.geom,26911) geom, p.pt_sizeclass,p. pt_startdate,r.name
FROM nv_road r, point_buffer p
WHERE ST_intersects(ST_transform(p.buffergeom,26911),ST_transform(r.geom,26911))

--which urban area has the higher influence FROM the wildfire. 
--wildfire area that intersects WITH the urban area's 2km buffer
WITH urban_buffer AS (--create a 2km buffer
SELECT ST_buffer(ST_transform(geom,26911),2000) AS ubuffer_geom, geom,
gid, area_type,urban_name
FROM nv_urbanarea_2010c)
--get the sum of area burned in sqkm
SELECT sum(p.pt_totacres)*0.00404686 AS total_sqkm, u.geom, 
u.area_type, u.urban_name
FROM join_wf p, urban_buffer u
WHERE ST_intersects(ST_transform(u.ubuffer_geom,26911),ST_transform(p.pt_geom,26911))
GROUP BY u.area_type,u.urban_name, u.geom
