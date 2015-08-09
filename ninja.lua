--
-- Name:        premake-ninja/ninja.lua
-- Purpose:     Define the ninja action.
-- Author:      Dmitry Ivanov
-- Created:     2015/07/04
-- Copyright:   (c) 2015 Dmitry Ivanov
--

local p = premake
local tree = p.tree
local project = p.project
local solution = p.solution
local config = p.config
local fileconfig = p.fileconfig

premake.modules.ninja = {}
local ninja = p.modules.ninja

function ninja.esc(value)
	-- str = str.replace("$", "$$").replace(":", "$:").replace("\n", "$\n")

	--print("'" .. value .. "'")
	value = string.gsub(value, "%$", "$$")
	value = string.gsub(value, ":", "$:")
	value = string.gsub(value, "\n", "$\n")
	value = string.gsub(value, " ", "$ ")
	--print("'" .. value .. "'")
	return value -- TODO
end

-- generate solution that will call ninja for projects
function ninja.generateSolution(sln)
	p.w("# solution build file")
	p.w("# generated with premake ninja")
	p.w("")

	p.w("# build projects")
	local cfgs = {} -- key is configuration name, value is string of outputs names
	local cfg_first = nil
	for prj in solution.eachproject(sln) do
		for cfg in project.eachconfig(prj) do

			-- fill list of output files
			if not cfgs[cfg.name] then cfgs[cfg.name] = "" end
			cfgs[cfg.name] = cfgs[cfg.name] .. p.esc(ninja.outputFilename(cfg)) .. " "

			-- set first configuration name
			if cfg_first == nil then cfg_first = cfg.name end

			-- include other ninja file
			p.w("subninja " .. p.esc(ninja.projectCfgFilename(cfg)))
		end
	end
	p.w("")

	p.w("# targets")
	for cfg, outputs in pairs(cfgs) do
		p.w("build " .. cfg .. ": phony " .. outputs)
	end
	p.w("")

	p.w("# default target")
	p.w("default " .. cfg_first)
end

function ninja.list(value)
	if #value > 0 then
		return " " .. table.concat(value, " ")
	else
		return ""
	end
end

-- generate project + config build file
function ninja.generateProjectCfg(cfg)
	local toolset_name = _OPTIONS.cc or cfg.toolset
	local system_name = os.get()

	if toolset_name == nil then -- TODO why premake doesn't provide default name always ?
		if system_name == "windows" then
			toolset_name = "msc"
		elseif system_name == "macosx" then
			toolset_name = "clang"
		elseif system_name == "linux" then
			toolset_name = "gcc"
		else
			toolset_name = "gcc"
			p.warnOnce("unknown_system", "no toolchain set and unknown system " .. system_name .. " so assuming toolchain is gcc")
		end
	end

	local prj = cfg.project
	local toolset = p.tools[toolset_name]

	p.w("# project build file")
	p.w("# generated with premake ninja")
	p.w("")

	-- premake-ninja relies on scoped rules
	-- and they were added in ninja v1.6
	p.w("ninja_required_version = 1.6")
	p.w("")

	---------------------------------------------------- figure out toolset executables
	local cc = ""
	local cxx = ""
	local ar = ""
	local link = ""
	
	if toolset_name == "msc" then
		-- TODO premake doesn't set tools names for msc, do we want to fix it ?
		cc = "cl"
		cxx = "cl"
		ar = "lib"
		link = "cl"
	elseif toolset_name == "clang" then
		cc = toolset:gettoolname("cc")
		cxx = toolset:gettoolname("cxx")
		ar = toolset:gettoolname("ar")
		link = toolset:gettoolname("cc")
	elseif toolset_name == "gcc" then
		if not cfg.gccprefix then cfg.gccprefix = "" end
		cc = toolset.gettoolname(cfg, "cc")
		cxx = toolset.gettoolname(cfg, "cxx")
		ar = toolset.gettoolname(cfg, "ar")
		link = toolset.gettoolname(cfg, "cc")
	else
		p.error("unknown toolchain " .. toolset_name)
	end

	---------------------------------------------------- figure out settings
	local buildopt =		ninja.list(cfg.buildoptions)
	local cflags =			ninja.list(toolset.getcflags(cfg))
	local cppflags =		ninja.list(toolset.getcppflags(cfg))
	local cxxflags =		ninja.list(toolset.getcxxflags(cfg))
	local warnings =		""
	local defines =			ninja.list(table.join(toolset.getdefines(cfg.defines), toolset.getundefines(cfg.undefines)))
	local includes =		ninja.list(toolset.getincludedirs(cfg, cfg.includedirs, cfg.sysincludedirs))
	local forceincludes =	ninja.list(toolset.getforceincludes(cfg)) -- TODO pch
	local ldflags =			ninja.list(table.join(toolset.getLibraryDirectories(cfg), toolset.getldflags(cfg), cfg.linkoptions))
	local libs =			""

	if toolset_name == "msc" then
		warnings = ninja.list(toolset.getwarnings(cfg))
		-- we don't pass getlinks(cfg) through dependencies
		-- because system libraries are often not in PATH so ninja can't find them
		libs = ninja.list(p.esc(config.getlinks(cfg, "siblings", "fullpath")))
	elseif toolset_name == "clang" then
		libs = ninja.list(p.esc(config.getlinks(cfg, "siblings", "fullpath")))
	elseif toolset_name == "gcc" then
		libs = ninja.list(p.esc(config.getlinks(cfg, "siblings", "fullpath")))
	end

	-- experimental feature, change install_name of shared libs
	--if (toolset_name == "clang") and (cfg.kind == p.SHAREDLIB) and ninja.endsWith(cfg.buildtarget.name, ".dylib") then
	--	ldflags = ldflags .. " -install_name " .. cfg.buildtarget.name
	--end

	local all_cflags = buildopt .. cflags .. warnings .. defines .. includes .. forceincludes
	local all_cxxflags = buildopt .. cflags .. cppflags .. cxxflags .. warnings .. defines .. includes .. forceincludes
	local all_ldflags = buildopt .. ldflags

	local obj_dir = project.getrelative(cfg.project, cfg.objdir)

	---------------------------------------------------- write rules
	p.w("# core rules for " .. cfg.name)
	if toolset_name == "msc" then -- TODO /NOLOGO is invalid, we need to use /nologo
		p.w("rule cc")
		p.w("  command = " .. cc .. all_cflags .. " /nologo /showIncludes -c $in /Fo$out")
		p.w("  description = cc $out")
		p.w("  deps = msvc")
		p.w("")
		p.w("rule cxx")
		p.w("  command = " .. cxx .. all_cxxflags .. " /nologo /showIncludes -c $in /Fo$out")
		p.w("  description = cxx $out")
		p.w("  deps = msvc")
		p.w("")
		p.w("rule ar")
		p.w("  command = " .. ar .. " $in /nologo -OUT:$out")
		p.w("  description = ar $out")
		p.w("")
		p.w("rule link")
		p.w("  command = " .. link .. " $in " .. ninja.list(toolset.getlinks(cfg)) .. " /link " .. all_ldflags .. " /nologo /out:$out")
		p.w("  description = link $out")
		p.w("")
	elseif toolset_name == "clang" then
		p.w("rule cc")
		p.w("  command = " .. cc .. all_cflags .. " -MMD -MF $out.d -c -o $out $in")
		p.w("  description = cc $out")
		p.w("  depfile = $out.d")
		p.w("  deps = gcc")
		p.w("")
		p.w("rule cxx")
		p.w("  command = " .. cxx .. all_cflags .. " -MMD -MF $out.d -c -o $out $in")
		p.w("  description = cxx $out")
		p.w("  depfile = $out.d")
		p.w("  deps = gcc")
		p.w("")
		p.w("rule ar")
		p.w("  command = " .. ar .. " rcs $out $in")
		p.w("  description = ar $out")
		p.w("")
		p.w("rule link")
		p.w("  command = " .. link .. all_ldflags .. " " .. ninja.list(toolset.getlinks(cfg)) .. " -o $out $in")
		p.w("  description = link $out")
		p.w("")
	elseif toolset_name == "gcc" then
		p.w("rule cc")
		p.w("  command = " .. cc .. all_cflags .. " -MMD -MF $out.d -c -o $out $in")
		p.w("  description = cc $out")
		p.w("  depfile = $out.d")
		p.w("  deps = gcc")
		p.w("")
		p.w("rule cxx")
		p.w("  command = " .. cxx .. all_cflags .. " -MMD -MF $out.d -c -o $out $in")
		p.w("  description = cxx $out")
		p.w("  depfile = $out.d")
		p.w("  deps = gcc")
		p.w("")
		p.w("rule ar")
		p.w("  command = " .. ar .. " rcs $out $in")
		p.w("  description = ar $out")
		p.w("")
		p.w("rule link")
		p.w("  command = " .. link .. all_ldflags .. " " .. ninja.list(toolset.getlinks(cfg)) .. " -o $out $in")
		p.w("  description = link $out")
		p.w("")
	end

	---------------------------------------------------- build all files
	p.w("# build files")
	local intermediateExt = function(cfg, var)
		if (var == "c") or (var == "cxx") then
			return iif(toolset_name == "msc", ".obj", ".o")
		elseif var == "res" then
			-- TODO
			return ".res"
		elseif var == "link" then
			return cfg.targetextension
		end
	end
	local objfiles = {}
	tree.traverse(project.getsourcetree(prj), {
	onleaf = function(node, depth)
		local filecfg = fileconfig.getconfig(node, cfg)
		if fileconfig.hasCustomBuildRule(filecfg) then
			-- TODO
		elseif path.iscppfile(node.abspath) then
			objfilename = obj_dir .. "/" .. node.objname .. intermediateExt(cfg, "cxx")
			objfiles[#objfiles + 1] = objfilename
			if ninja.endsWith(node.relpath, ".c") then
				p.w("build " .. p.esc(objfilename) .. ": cc " .. p.esc(node.relpath))
			else
				p.w("build " .. p.esc(objfilename) .. ": cxx " .. p.esc(node.relpath))
			end
		elseif path.isresourcefile(node.abspath) then
			-- TODO
		end
	end,
	}, false, 1)
	p.w("")

	---------------------------------------------------- build final target
	if cfg.kind == p.STATICLIB then
		p.w("# link static lib")
		p.w("build " .. p.esc(ninja.outputFilename(cfg)) .. ": ar " .. table.concat(p.esc(objfiles), " ") .. " " .. libs)

	elseif cfg.kind == p.SHAREDLIB then
		local output = ninja.outputFilename(cfg)
		p.w("# link shared lib")
		p.w("build " .. p.esc(output) .. ": link " .. table.concat(p.esc(objfiles), " ") .. " " .. libs)

		-- TODO I'm a bit confused here, previous build statement builds .dll/.so file
		-- but there are like no obvious way to tell ninja that .lib/.a is also build there
		-- and we use .lib/.a later on as dependency for linkage
		-- so let's create phony build statements for this, not sure if it's the best solution
		-- UPD this can be fixed by https://github.com/martine/ninja/pull/989
		if ninja.endsWith(output, ".dll") then
			p.w("build " .. p.esc(ninja.noext(output, ".dll")) .. ".lib: phony " .. p.esc(output))
		elseif ninja.endsWith(output, ".so") then
			p.w("build " .. p.esc(ninja.noext(output, ".so")) .. ".a: phony " .. p.esc(output))
		elseif ninja.endsWith(output, ".dylib") then
			-- but in case of .dylib there are no corresponding .a file
		else
			p.error("unknown type of shared lib '" .. output .. "', so no idea what to do, sorry")
		end

	elseif (cfg.kind == p.CONSOLEAPP) or (cfg.kind == p.WINDOWEDAPP) then
		p.w("# link executable")
		p.w("build " .. p.esc(ninja.outputFilename(cfg)) .. ": link " .. table.concat(p.esc(objfiles), " ") .. " " .. libs)

	else
		p.error("ninja action doesn't support this kind of target " .. cfg.kind)
	end
end

-- return name of output binary relative to build folder
function ninja.outputFilename(cfg)
	return project.getrelative(cfg.project, cfg.buildtarget.directory) .. "/" .. cfg.buildtarget.name
end

-- return name of build file for configuration
function ninja.projectCfgFilename(cfg)
	return "build_" .. cfg.project.name  .. "_" .. cfg.name .. ".ninja"
end

-- check if string starts with string
function ninja.startsWith(str, starts)
	return str:sub(0, starts:len()) == starts
end

-- check if string ends with string
function ninja.endsWith(str, ends)
	return str:sub(-ends:len()) == ends
end

-- removes extension from string
function ninja.noext(str, ext)
	return str:sub(0, str:len() - ext:len())
end

-- generate all build files for every project configuration
function ninja.generateProject(prj)
	for cfg in project.eachconfig(prj) do
		p.generate(cfg, ninja.projectCfgFilename(cfg), ninja.generateProjectCfg)
	end
end

include("_preload.lua")

return ninja
