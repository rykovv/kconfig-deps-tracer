#!/bin/bash

# This script will recieve following arguments:
#   1. kernel .config
#   2. file with deps to be checked

unset -v CONFIG
unset -v DEPS

help()
{
    # Display Help
    echo "Script that traces missing Linux kernel dependencies for provided modules."
    echo
    echo "Syntax: kconfig-deps-tracer [-h|c|d]"
    echo "options:"
    echo "h     Print help for using the script."
    echo "c     Kernel build configuration file (.config)."
    echo "d     File with dependencies to be traced."
    echo
}

L=0
to_be_added=()
to_be_ignored=()
being_analyzed=()

traverse_deps_rec()
{
    local dep=$1
    local file=$2
    local found=""
    local end_block=""
    local pat1="config $dep"
    local pat2="menuconfig $dep"
    local next_dep=""
    echo "$L - in traverse_deps_rec($dep, $filename)"
    while IFS= read line; do
	if [[ -z "$found" ]]; then
	    if [[ "$line" =~ $pat1 ]] || [[ "$line" =~ $pat2 ]]; then
	        echo "$L - localized! $line"
	        found="y"
	    fi
	else
	    # next config found, time to go back
            if [[ $line =~ ^"config" ]]; then
                echo "$L - end config"
	        end_block="y"
	    else
	        #echo "not yet"
		read -a aline <<< $line
		if [[ "${aline[0]}" == "depends" ]]; then
		    echo "$L - found dependency ${line#*depends on }"
		    next_dep=${line#*depends on }
		elif [[ "${aline[0]}" == "select" ]]; then
		    echo "$L - found dependency ${line#*select }"
		    next_dep=${line#*select }
		fi
		if [[ ! -z "$next_dep" ]]; then
		    # conditionals can be complex
                    if [[ $next_dep =~ [[:space:]]+ ]]; then
		        # contains spaces -> complex condition
			echo "$L - '$next_dep' will be ignored"
			to_be_ignored+=("$next_dep")
		    else
			# analyze simple
			if [[ ${next_dep:0:3} =~ ^[[:upper:][:digit:]_]+$ ]]; then
                            L=$((L+1))
		            analyze_dep $next_dep
			    L=$((L-1))
			else
			    echo "$L - not a dependency '$next_dep'"
			    to_be_ignored+=("$next_dep")
			fi
		    fi
                    : '
		    IFS=" " read -a conditionals <<< $next_dep
	            for c in "${conditionals[@]}"; do
			# consider if !(C1 || C2 && ...) ?
			if [[ "$c" != "||" ]] && [[ "$c" != "&&" ]] && [[ "$c" != "if" ]] && [[ "$c" != "=" ]] && [[ "$c" != "y" ]] && [[ "$c" != "n" ]]; then
                            L=$((L+1))
			    # trim leading parenthesis
			    # trim trailing parenthesis
			    tc="${c#(*}"
                            tc="${tc%*)}"
                            #if [[ $tc =~ [A-Z0-9] ]]; then
			    if [[ ${tc:0:3} =~ ^[[:upper:][:digit:]_]+$ ]]; then
		                analyze_dep $tc
			    else
				echo "not a dependency '$tc'"
			    fi
		            L=$((L-1))
			fi
	            done
		    '
		#else
		#   echo "$L - add $dep to $CONFIG"
		fi
	    fi
	fi
	if [[ ! -z $end_block ]]; then
	    echo "$L - add $dep to $CONFIG"
	    to_be_added+=("CONFIG_$dep=$mod")
            return
	fi
	next_dep=""
    done < $file
}

analyze_dep()
{
    echo "$L - -------------------------"
    local dep=$1
    local filename=""
    #echo "to_be_added: ${to_be_added[@]}"
    if [[ ! " ${to_be_added[*]} " =~ [[:space:]]CONFIG_$dep=$mod[[:space:]] ]]; then
	#echo "has not been added: CONFIG_$dep=$mod"
        case `grep -Fx -e "CONFIG_$dep=y" -e "CONFIG_$dep=m" "$CONFIG" >/dev/null; echo $?` in
	    0) # found dep
                echo "$L - $dep already satisfied"
                ;;
    	    1) # not found
                # 2. if not satisfied
                echo "$L - CONFIG_$dep not satisfied"
	        #nopref=${dep#*_} # cut prefix until first '_'
	        #dep=${nopref%=*} # cut postfix after '='
                echo "$L - looking for ${dep}"
                # 2.1 find file with a missing dependency definition
	        filename=`grep -Fxnrl --include \*Kconfig* --exclude-dir="build-*" -e "config ${dep}" -e "menuconfig ${dep}"`
                if [[ ! -z "$filename" ]]; then
                    echo "$L - found in $filename"
	            # 2.2 look recursively (depth-first) for all lower-level dependencies		    
                    if [[ ! " ${being_analyzed[*]} " =~ [[:space:]]${dep}[[:space:]] ]]; then
			being_analyzed+=($dep)
			traverse_deps_rec $dep $filename
			being_analyzed=("${being_analyzed[@]/$dep}")
		    else
	                echo "------------------------------------ $dep being analyzed"
	            fi
	            #exit 0
	        else
		    echo "$L - non-localized dependency"
	        fi
                ;;
	    *) # error occured
	        #echo "Error occcurred during analysis"
	        ;;
        esac
    else
	echo "$L - $dep has been already added"
    fi
    echo "$L - -------------------------"
}	

# get options
while getopts ":hc:d:" option; do
    case $option in
        h) # display help
	    help
	    exit;;
	c) # get config file
	    CONFIG=$OPTARG;;
        d) # get deps
	    DEPS=$OPTARG;;
	\?) # invalid
	    echo "Error: Invalid option." >&2
	    echo "Run kconfig-deps-tracer -h for help."
	    exit;;
    esac
done
	    
# check mandatory args
if [ -z "$CONFIG" ] || [ -z "$DEPS" ]; then
    echo "Missing -c or -d" >&2
    echo "Run kconfig-deps-tracer -h for help."
    exit 1
fi

echo ".config = $CONFIG"
echo ".deps = $DEPS"

while read -r dep; do
    if [[ $dep == CONFIG_* ]]; then
	orig=$dep
	nopref=${dep#*_} # cut prefix (CONFIG_) until first '_'
	mod=${dep#*=} # get module value to be added
	dep=${nopref%=*} # cut postfix after '=' (={y,n,m,whatever})
	if [[ $mod == "m" ]] || [[ $mod == "y" ]] || [[ $mod == "n" ]]; then
	    analyze_dep $dep
	else
	    echo "$L - ignore non-module dep '$orig'"
	fi
    fi
done < $DEPS

echo "Final list of dependencies: "
echo ${to_be_added[*]}
echo "" > missing_deps
for dep in "${to_be_added[@]}"; do
    echo $dep >> missing_deps
done
echo "" > ignored_deps
for dep in "${to_be_ignored[@]}"; do
    echo $dep >> ignored_deps
done
