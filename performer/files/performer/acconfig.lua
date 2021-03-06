local ski = require("ski")
local log = require("log")
local js = require("cjson.safe")
local rpccli = require("rpccli")
local simplesql = require("simplesql")


local tcp_map = {}

--database related
local mqtt, simple

local ConfigType = {"Rule", "Set"}		--two type config
local ConfigCate = {"Control", "Audit"}	--every type contains two categories config

local ControlSet 		= "ControlSet"
local ControlRule 		= "ControlRule"
local AuditSet 			= "AuditSet"
local AuditRule 		= "AuditRule"

local ipset_map = {
	["MacWhiteList"] = {set_key = "MacWhiteListSetName", set_type = "hash:mac"},
	["IpWhiteList"] = {set_key = "IpWhiteListSetName", set_type = "hash:ip"} ,
	["MacBlackList"] = {set_key = "MacBlackListSetName", set_type = "hash:mac"},
	["IpBlackList"] = {set_key = "IpBlackListSetName", set_type = "hash:mac"},
}


--[[
Both rules and sets support disable and enable option.
When disable is set, all rules or ip&mac are cleared in kernel
When enable is set, rules or ip&mac are set to kernel
fixme: it's not a good practice:it always do check option in kernel, even disable is set.
this will cost cpu, of course, the cost is very low.
--]]

--[[
ac rules process flow:
a.fetch config from db: periodical timer timeout or receiving config update news
b.translate the config to new_ac_rules
c.compare cur_ac_rules and new_ac_rules:if they are different, reset config to kernel, and then update cur_ac_rules with new_ac_rules
Notice:control rules and audit rules are independently.
rules = {[ControlRule] = {xxx}, [AuditRule] = {xxx}}

ip & mac blacklist or whitelist.Support ip range and single ip.
ac sets process flow:
a.fetch config from db:receving config update news
b.translate the config to new_ac_sets:add/del items of ip or mac;disable or enable is set
c.compare cur_ac_sets and new_ac_sets:if they are different, reset config to kernel with ipset,
	and then update cur_ac_sets with new_ac_sets
--]]

--raw configs
local all_raw_ac_config = {}
-- {["Rule"] = {["Audit"] = {}, ["Control"] = {}}, ["Set"] = {["Audit"] = {}, ["Control"] = {}}}
--translated config of current config
local cur_ac_config = {}
--translated config of lastest config
local new_ac_config = {}

--[[
	audit/control rule fromat:
	{
		"Id":,

		"SrcZoneIds":[],
		"SrcIpgrpIds":[],
		"DstZoneIds":[],
		"DstIpgrpIds":[],
		"ProtoIds":[],
		"Action":["ACCEPT", "AUDIT"]
	},

	structure of acconfig that ruletable can parse.
	{
		"ControlSet":{
				{"MacWhiteListSetName":CtrlMacWhiteListSet, "MacWhite":[]},
				{"IpWhiteListSetName":CtrlIpWhiteListSet, 	"IpWhite":[]},
				{"MacBlackListSetName"CtrlMacBlackListSet, "MacBlack":[]},
				{"IpBlackListSetName":CtrlIpBlackListSet, "IpBlack":[]}
		},

		"ControlRule": [],

		"AuditSet": {
				{"MacWhiteListSetName":AuditMacWhiteListSet, "MacWhite":[]},
				{"IpWhiteListSetName":AuditIpWhiteListSet, 	"IpWhite":[]},
		},

		"AuditRule":[]
	}
--]]


--[[
compare array
@old, new both of them are array
@return true--different, false--same
]]
local function array_cmp(old, new)
	local _ = assert(old), assert(new)
	local old_map, new_map = {}, {}
	if type(old) ~= "table" or type(new) ~= "table" or
		(cmp_func and type(cmp_func) ~= "table") then
		return nil, "invalid parameters"
	end

	if #old ~= #new then
		return true
	end

	for _, v in ipairs(old) do
		old_map[v] = 1
	end

	for _, v in ipairs(new) do
		new_map[v] = 1
	end

	for k, v in pairs(new_map) do
		if not old_map[k]  then
			return true
		end
	end
	return false
end


--[[
config map:
@set_type: Mac or Ip
--]]
local function set_list_cmp(old, new, set_type)



	print("set_list_cmp old:", js.encode(old))
	print("set_list_cmp new:", js.encode(new))
	return true
end

--[[
compare rule one by one
--]]
local function ac_rule_cmp(old, new)
	local _ = assert(old), assert(new)

	if type(old) ~= "table" or type(new) ~= "table" then
		return nil, "invalid parameters"
	end

	if #old ~= #new then
		return true
	end

	local sorted_arr_keys = {"SrcZoneIds", "SrcIpgrpIds", "DstZoneIds", "DstIpgrpIds", "ProtoIds"}

	for i=1, #old do
		local old_item, new_item = old[i], new[i]
		local old_ids, new_ids = {}, {}

		if old_item["Id"] ~= new_item["Id"] then
			return true
		end

		for _, key in ipairs(sorted_arr_keys) do
			if array_cmp(old_item[key], old_item[key]) then
				return true
			end
		end

		for _, key in pairs({"ACCEPT", "REJECT", "AUDIT"}) do
 			if old_item[key] ~= new_item[key] then
 				return true
 			end
 		end
	end

	return false
end

--[[
Check whether tm is contained by tmlist
the tmgrp format is {days = {}, tmlist = []}
tm is provided by os.time()
--]]
local function tm_contained(tmgrps, tm)
	local cur_tm = tm
	local cur_weekday = tostring(os.date("%w", tm)) --0~6 sunday~saturday
	local cur_year = os.date("%Y", tm)
	local cur_month = os.date("%m", tm)
	local cur_day = os.date("%d", tm)

	local day_map = {
		["0"] = "sun",
		["1"] = "mon",
		["2"] = "tues",
		["3"] = "wed",
		["4"] = "thur",
		["5"] = "fri",
		["6"] = "sat",
	}
	local cur_tmgrp

	local day_key = day_map[cur_weekday] assert(day_key)
	for _, tmgrp in ipairs(tmgrps) do
		for day_name, day_value in pairs(tmgrp.days) do
			if day_name == day_key then
				if day_value ~= 1 then
					return false
				end
				cur_tmgrp = tmgrp
				break
			end
		end
	end

	for _, tm_item in ipairs(cur_tmgrp.tmlist) do
		local start_tm = os.time({year = cur_year, month = cur_month, day = cur_day,
									hour = tm_item.hour_start, min = tm_item.min_start})
		local end_tm = os.time({year = cur_year, month = cur_month, day = cur_day,
									hour = tm_item.hour_end, min = tm_item.min_end})
		if os.difftime(tm, start_tm) >= 0 and os.difftime(end_tm, tm) >= 0 then
			return true
		end
	end

	return false
end


--[[
commit config to kernel
cate:audit or control
sub_cate:ipblack/white, macblack/white

{
	"Id":1,"SrcZoneIds":[1,2],"SrcIpgrpIds":[3,4],
	"DstZoneIds":[5,6],"DstIpgrpIds":[7,8],
	"ProtoIds":[0,9],"Action":["ACCEPT","AUDIT"]
}
--]]
local commit_config = {}
--[[
commit rule config to kernel:
@cate_arr {{cate = Control/Audit}, {}}
@new_config {Control = {}, Audit = {}}
]]
commit_config["Rule"] = function(cate_arr, new_config)
	for _, item in ipairs(cate_arr) do
		local cate_config = {}
		local rule_key = item.cate.."Rule"
		
		cate_config[rule_key] = new_config[item.cate]
		local cmd_str = string.format("ruletalbe -s '%s'", js.encode(cate_config)) assert(cmd_str)
		print(cmd_str)
		--os.execute(cmd_str)
		return true
	end

	return true
end


--[[ 
{
["ipset_key"] = ipset_key, ["ipset_name"] = item.sub_cate, 
["ipset_type"] = ipset_type, ["ipset_list"] = set_item.set_list 
}
]]
local function reference_ipset(type_key, config, ref)
	local ref_map, item_map = {}, {}
	for _, info in ipairs(config) do
		item_map[info.ipset_key] = ref and info.ipset_name or ""
	end
	ref_map[type_key] = item_map

	local ref_cmd = string.format("ruletalbe -s '%s'", js.encode(ref_map))
	print("reference：", ref_cmd)
	return true
end

local function destroy_ipset(config)
	for _, info in ipairs(config) do
		local destroy_cmd = string.format("ipset destroy '%s'", info.ipset_name)
		print("destroy:", destroy_cmd)
	end
	return true
end


local function create_ipset(config)
	for _, info in ipairs(config) do 
		local create_cmd = string.format("ipset create '%s' '%s'", info.ipset_name, info.ipset_type)
		print("create:", create_cmd)
	end
	return true
end


local function update_ipset(config)
	for _, info in ipairs(config) do
		for _, item in ipairs(info.ipset_list) do
			local add_cmd = string.format("ipset add '%s' '%s'", info.ipset_name, item)
			print("add:", add_cmd)
		end
	end
	return true
end

--[[
commit set config to kernel:
@cate_arr {{cate = Control/Audit, sub_cate = xxx(setname)}, {}}
@new_config {"Audit":{"setname1":{"map_key":xxx, "set_list":xxx}, }, "Control":{xxx}}
]]
commit_config["Set"] = function(cate_arr, new_config)
	local _ = assert(cate_arr), assert(new_config)
	local cate_config, ret, err = {}

	print("\n\ncommit_config[set] cate_arr:",js.encode(cate_arr))
	if #cate_arr == 0 then
		return true
	end

	for _, item in ipairs(cate_arr) do
		if not cate_config[item.cate] then
			cate_config[item.cate] = {}
		end
		
		--["setname"]={["map_key"] = xxx, ["set_list"] = xx}
		local set_item = new_config[item.cate][item.sub_cate]	assert(set_item)
		local ipset_key = ipset_map[set_item.map_key].set_key   assert(ipset_key)
		local ipset_type = ipset_map[set_item.map_key].set_type assert(ipset_type)
		local commit_item = 
			{
				["ipset_key"] = ipset_key, 
				["ipset_name"] = item.sub_cate, 
				["ipset_type"] = ipset_type, 
				["ipset_list"] = set_item.set_list 
			}
		--print("commit_item:", js.encode(commit_item))
		table.insert(cate_config[item.cate], commit_item)
	end
	print("\n\ncommit_config[set] cate_config:",js.encode(cate_config))
	--dereference in kernel,destroy ipset, create ipset, reference in kernel, update ipset
	for cate, config in pairs(cate_config) do
		local cate_key = cate.."Set"
		ret, err = reference_ipset(cate_key, config, false)
		if not ret then
			return nil, err
		end

		ret, err = destroy_ipset(config)
		if not ret then
			return nil, err
		end

		ret, err = create_ipset(config)
		if not ret then
			return nil, err
		end

		ret, err = reference_ipset(cate_key, config, true)
		if not ret then
			return nil, err
		end

		ret, err = update_ipset(config)
		if not ret then
			return nil, err
		end
	end

	return true
end


--[[
compare config:
a.input parameters:old and old[cate] and new and new[cate] must be true
return format {ret = true/false, list = [{cate = Audit/Control, sub_cate = xx}, {}]}
Rule concerns only cate
--]]
local compare_config = {} 
compare_config["Rule"] = function(old, new)
	assert(new)
	local cmp_res, ret, err = {}, true

	--old is nil when process lanuched, need to update rule to kernel
	if old == nil then
		print("compare_config[rule]:old is nil")
		for _, cate in ipairs(ConfigCate) do
			table.insert(cmp_res, {["cate"] = cate})
		end
		return cmp_res
	end

	print("old:", js.encode(old))
	print("new:", js.encode(new))
	for _, cate in ipairs(ConfigCate) do
		if old[cate] == nil or new[cate] == nil then
			err = string.format("old[%s] is %s, new[%s] is %s", 
								old[cate] and "not nil" or "nil",
								new[cate] and "not nil" or "nil")
			return nil, err
		end

		print("old cate:", js.encode(old[cate]))
		print("new cate:", js.encode(new[cate]))
		--maybe a error occured
		ret, err = ac_rule_cmp(old[cate], new[cate])
		if not ret and err then
			return nil, err
		end
		local _ = ret and table.insert(cmp_res, {["cate"] = cate})
	end
	return cmp_res
end

--[[
compare set config
@old, new   
	{"Audit": 
		{
	        "AuditIPWhiteListSet": {"map_key": "IpWhiteList", "set_list": []},
	        "AuditMacWhiteListSet": {"map_key": "MacWhiteList", "set_list": []}
	    },
	  "Control":{}
	}
return format [{cate = Audit/Control, sub_cate = xx},]
Set concerns both cate and subcate
--]]
compare_config["Set"] = function(old, new)
	assert(new)
	local cmp_res, ret, err = {}, true
	--old is nil when process lanuched, need to update rule to kernel
	if old == nil then
		print("old is nil")
		for _, cate in ipairs(ConfigCate) do
			for name, info in pairs(new[cate]) do
				table.insert(cmp_res, {["cate"] = cate, ["sub_cate"] = name})
			end
		end
		return cmp_res
	end

	print("\n\n\ncompare_config[set] old:", js.encode(old))
	print("\n\n\ncompare_config[set] new:", js.encode(new))
	for _, cate in ipairs(ConfigCate) do
		local new_cate_config, old_cate_config = new[cate], old[cate]
		for name, info in pairs(new_cate_config) do
			local new_list = info.set_list
			local old_list = old_cate_config[name].set_list
			
			local ret, err = array_cmp(old_list, new_list)
			if not ret and err then
				return nil, err
			end
			local _ = ret and table.insert(cmp_res, {["cate"] = cate, ["sub_cate"] = name})
		end
	end

	return cmp_res
end

--[[
		"Id":,
		"SrcZoneIds":[],
		"SrcIpgrpIds":[],
		"DstZoneIds":[],
		"DstIpgrpIds":[],
		"ProtoIds":[],
		"Action":["ACCEPT", "AUDIT"]
		"TmGrp":{days = "{}", tmlist = ""}
--]]
local translate_config = {}
--generate two categories rule config:audit and control
translate_config["Rule"] = function(raw_rule_config)
	local generate_rule = function(rule_config, cur_tm)
		local rule_arr, rule_item = {}, {}
		print("----before translate rule:", js.encode(rule_config))
		for _, item in ipairs(rule_config) do 
			if tm_contained(item["TmGrp"], cur_tm) then
				rule_item["Id"] = item["ruleid"]
				rule_item["SrcZoneIds"] = js.decode(item["srczoneids"]) or {}
				rule_item["SrcIpgrpIds"] = js.decode(item["srcipgrpids"]) or {}
				rule_item["DstZoneIds"] = js.decode(item["dstzoneids"])	or {}
				rule_item["DstIpgrpIds"] = js.decode(item["dstipgrpids"]) or {}
				rule_item["ProtoIds"] = js.decode(item["protoids"])	or {}
				local _ = #rule_item["ProtoIds"] and table.sort(rule_item["ProtoIds"])
				rule_item["Actions"] = js.decode(item["actions"]) or {}
				table.insert(rule_arr, rule_item)
			else
				print("----time diff:", js.encode(item["TmGrp"]), os.date("%Y%h%m %H%M%s",cur_tm))
			end
		end
		print("----after translate rule:", js.encode(rule_arr))
		return rule_arr
	end

	local cur_tm, rule_config = os.time(), {}
	for _, cate in ipairs(ConfigCate) do
		local tmp_config, err = {}
		if raw_rule_config[cate] and #raw_rule_config[cate] > 0 then
	 		tmp_config, err = generate_rule(raw_rule_config[cate], cur_tm)
			if not tmp_config then
				return nil, err
			end
		end
		rule_config[cate] = tmp_config 
	end

	return rule_config
end

--[[
generate two categories set config:audit and control
output:
	{
	"Control":{
		setname1:{map_key=xx,set_list = xx},
		setname2:{map_key=xx,set_list = xx}
	},
	"Audit":{}
	}
--]]
translate_config["Set"] = function(raw_set_config)
	local generate_set = function(set_config)
		local set_map = {}
		for _, set_info in ipairs(set_config) do
			local ipset_key
			if set_info["settype"] == "Ip" then
				ipset_key = (set_info["actions"] == "Bypass") and  "IpWhiteList" or "IpBlackList"

			elseif set_info["settype"] == "Mac" then
				ipset_key = (set_info["actions"] == "Bypass") and  "MacWhiteList" or "MacBlackList"
			
			else
				return nil, "invalid settype"
			end
			
			set_content = set_info["state"] == "enable" and js.decode(set_info["setcontent"]) or {}
			if set_info["settype"] == "Ip" and #set_content > 0 then
				print("todo:correct ip list!!!!!!")
			end
			set_map[set_info["setname"]] = {["map_key"] = ipset_key, ["set_list"] = set_content}
		end

		return set_map
	end

	local set_config = {}
	for _, cate in ipairs(ConfigCate) do
		local tmp_config, err = {}
		if raw_set_config[cate] and #raw_set_config[cate] > 0 then
			tmp_config, err = generate_set(raw_set_config[cate])
			if not tmp_config then
				print("translate_config[set] error:", err)
				return nil, err
			end
		end
		set_config[cate] = tmp_config
	end
	--print("translate_config[set]:",js.encode(set_config))
	return set_config
end


local fetch_raw_config = {}
--fetch two categories rule config:audit and control
fetch_raw_config["Rule"] = function()
	local fetch_rule = function(cate)
		local sql = string.format("select * from acrule where ruletype='%s' and state='enable' order by priority desc", cate) 
		if not sql then
			return nil, "construct sql failed"
		end
		
		local rule_arr = {}
		local tmp_arr, err = simple:mysql_select(sql)
		--print("----sql:", sql, "data:", js.encode(tmp_arr))

		if err then
			return nil, err
		end

		for _, rule in ipairs(tmp_arr) do
			--print("tmpgrpids:", rule["tmgrpids"])
			local tmgrps = {}
			local tmgrpids = rule["tmgrpids"] and js.decode(rule["tmgrpids"]) or {}

			if #tmgrpids == 0 then
				return nil, "tmgrpids is empty"
			end
	
			local sql = string.format("select days,tmlist from timegroup where tmgid in (%s)", table.concat(tmgrpids, ",")) 
			if not sql then
				return nil, "construct sql failed"
			end

			local detail_arr, err = simple:mysql_select(sql)
			if not detail_arr or #detail_arr == 0 then
				return nil, err or string.format("invalid time groups:(%s)", table.concat(tmgrpids, ","))
			end

			for _, detail in ipairs(detail_arr) do
				local days = js.decode(detail.days)		
				local tmlist = js.decode(detail.tmlist)	
				
				if days == nil or tmlist == nil then
					return nil, "decode tm detail failed"
				end
				table.insert(tmgrps, {days = days, tmlist = tmlist})
			end
			--print("----sql:", sql, "data:", js.encode(detail_arr))

			if tmgrps and #tmgrps > 0 then
				--notice: translate ids to detail info
				rule["TmGrp"] = tmgrps
				rule["tmgrpids"] = nil
				table.insert(rule_arr, rule)
			end
		end
		-- print("-----tmp_arr:",js.encode(tmp_arr))
		-- print("-----rule_arr:",js.encode(rule_arr))
		return rule_arr
	end

	local rule_config = {}
	for _, cate in ipairs(ConfigCate) do
		local res, err = fetch_rule(cate) 
		if not res then
			--if fetch failed, ignore what already have fetched
			return nil, err
		end
		rule_config[cate] = res
	end

	return rule_config
end

--fetch two categories set config:audit and control
fetch_raw_config["Set"] = function()
	local fetch_set = function(cate)
		--notice:we need all setname, so ignore whether state is enable or disable
		local sql = string.format("select * from acipset where setcate='%s'", cate) assert(sql)
		if not sql then
			return nil, "construct sql failed"
		end

		local set_arr, err = simple:mysql_select(sql)
		if err then
			return nil, err
		end
		
		return set_arr
	end

	local set_config = {}
	--notice:Control contains four ipsets; Audit contains two ipsets
	local check_number = {["Control"] = 4, ["Audit"] = 2}
	for _, cate in ipairs(ConfigCate) do
		local number = 0
		local res, err = fetch_set(cate)
		if not res then
			return nil, err
		end
		--must check ipset intergrity
		if #res ~= check_number[cate] then
			return nil, string.format("fetch %s set number: real(%d) ~= expected(%d)", cate, #res, check_number[cate])
		end
		set_config[cate] = res
	end
	return set_config
end


--load config:Rule and set
local function load_config()
	local raw_config = {}
	for _, config_type in ipairs(ConfigType) do
		local func = fetch_raw_config[config_type] assert(func)
		local tmp_config, err = func()
		if not tmp_config then
			log.error("fetch config(type=%s) failed for %s", config_type, err)
			print("load_config err:", err)
			return false
		end
		raw_config[config_type] = tmp_config
	end

	all_raw_ac_config = raw_config
	print("-----------load_config:", js.encode(all_raw_ac_config))
	log.info("load config sucess")
	return true
end

--[[
check config whether need update and commit:
a.reload config
b.translate raw config
c.compare new and old config
d.if config updated, commit config
--]]
local function check_config_update()
	if not load_config() then
		log.error("load config failed")
		return false
	end

	for _, config_type in ipairs(ConfigType) do
		local res, err
		local new_config, old_config
		local trans_func = translate_config[config_type] 	assert(trans_func)
		local cmp_func =  compare_config[config_type]		assert(cmp_func)
		local commit_func = commit_config[config_type]		assert(commit_func)

		new_config, err = trans_func(all_raw_ac_config[config_type])
		if not new_config then
			log.error("translate config(type=%s) failed for %s", config_type, err)
			return false
		end
		new_ac_config[config_type] = new_config
		old_config = cur_ac_config[config_type]

		--a array which contains：[{cate = Audit/Control, sub_cate = xx}, ]
		res, err = cmp_func(old_config, new_config)
		if not res then
			log.error("compare config(type=%s) failed for %s", config_type, err)
			return false
		end
		print("----compare res----:", js.encode(res))
		local _ = #res == 0 and print("nothing changed, no need to reset!")

		if #res > 0 then
			res, err = commit_func(res, new_ac_config[config_type])
			if not res then
				log.error("commit config(type=%s) failed for %s", config_type, err)
				print("commit config error: ", config_type, " ", err)
				return false
			end
			print("----commit_func res----:", js.encode(res))
			print("\n\n\n--1--cur_ac_config:", config_type, js.encode(cur_ac_config[config_type]))
			print("\n\n\n--1--new_ac_config:", config_type, js.encode(new_ac_config[config_type]))
			--notice:update config after commit success
			cur_ac_config[config_type] = new_ac_config[config_type]
		end
	end
	return true
end

--[[
fetch config immediately when receiving
--]]
local function force_check_config_update()
	load_config()
	check_config_update()
end

--periodical routine
local function run_routine()
	while true do
		check_config_update()
		ski.sleep(60)
	end
end


tcp_map["dbsync_ipgroup"] = function(p)
	print("-----acconfig:", js.encode(p))
	force_check_config_update()
	return true
end


tcp_map["dbsync_timegroup"] = function(p)
	print("-----acconfig:", js.encode(p))
	force_check_config_update()
	return true

end

tcp_map["dbsync_acrule"] = function(p)
	print("-----acconfig:", js.encode(p))
	force_check_config_update()
	return true
end


tcp_map["dbsync_acipset"] = function(p)
	print("-----acconfig:", js.encode(p))
	force_check_config_update()
	return true
end


local function dispatch_tcp(cmd)
	local f = tcp_map[cmd.cmd]
	if f then
		return true, f(cmd)
	end
end

--entrance of acconfig
local function init(p)
	mqtt = p

	local dbrpc = rpccli.new(mqtt, "a/local/database_srv")
	if not dbrpc then
		log.error("create rpccli failed")
		return false
	end

	simple = simplesql.new(dbrpc)
	if not simple then
		log.error("create simple sql failed")
		return false
	end
	ski.go(run_routine)
end

return {init = init, dispatch_tcp = dispatch_tcp}