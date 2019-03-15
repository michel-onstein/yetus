#!/usr/bin/env bash
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# SHELLDOC-IGNORE

FINDBUGS_HOME=${FINDBUGS_HOME:-}
FINDBUGS_WARNINGS_FAIL_PRECHECK=false

add_test_type findbugs

function findbugs_usage
{
  yetus_add_option "--findbugs-home=<path>" "Findbugs home directory (default \${FINDBUGS_HOME})"
  yetus_add_option "--findbugs-strict-precheck" "If there are Findbugs warnings during precheck, fail"
}

function findbugs_parse_args
{
  declare i

  for i in "$@"; do
    case ${i} in
    --findbugs-home=*)
      FINDBUGS_HOME=${i#*=}
    ;;
    --findbugs-strict-precheck)
      FINDBUGS_WARNINGS_FAIL_PRECHECK=true
    ;;
    esac
  done
}

## @description  initialize the findbugs plug-in
## @audience     private
## @stability    evolving
## @replaceable  no
function findbugs_initialize
{
  if declare -f maven_add_install >/dev/null 2>&1; then
    maven_add_install findbugs
  fi
}

function findbugs_filefilter
{
  declare filename=$1

  if [[ ${BUILDTOOL} == maven
    || ${BUILDTOOL} == ant ]]; then
    if [[ ${filename} =~ \.java$
      || ${filename} =~ (^|/)findbugs-exclude.xml$ ]]; then
      add_test findbugs
    fi
  fi
}

function findbugs_precheck
{
  declare exec
  declare status=0

  if [[ -z ${FINDBUGS_HOME} ]]; then
    yetus_error "FINDBUGS_HOME was not specified."
    status=1
  else
    for exec in computeBugHistory \
                convertXmlToText \
                filterBugs \
                setBugDatabaseInfo\
                unionBugs; do
      if ! verify_command "${exec}" "${FINDBUGS_HOME}/bin/${exec}"; then
        status=1
      fi
    done
  fi
  if [[ ${status} == 1 ]]; then
    add_vote_table 0 findbugs "Findbugs executables are not available."
    delete_test findbugs
  fi
}

## @description  Run the maven findbugs plugin and record found issues in a bug database
## @audience     private
## @stability    evolving
## @replaceable  no
## @return       0 on success
## @return       1 on failure
## @param        repostatus
function findbugs_runner
{
  declare name=$1
  declare module
  declare result=0
  declare fn
  declare warnings_file
  declare i=0
  declare savestop
  declare retval


  personality_modules "${name}" findbugs

  "${BUILDTOOL}_modules_worker" "${name}" findbugs

  if [[ ${UNSUPPORTED_TEST} = true ]]; then
    return 0
  fi

  #shellcheck disable=SC2153
  until [[ ${i} -eq ${#MODULE[@]} ]]; do
    if [[ ${MODULE_STATUS[${i}]} == -1 ]]; then
      ((result=result+1))
      ((i=i+1))
      continue
    fi
    start_clock
    offset_clock "${MODULE_STATUS_TIMER[${i}]}"
    module="${MODULE[${i}]}"
    fn=$(module_file_fragment "${module}")

    if [[ "${module}" == . ]]; then
      module=root
    fi

    case ${BUILDTOOL} in
      maven)
        targetfile="findbugsXml.xml"
      ;;
      ant)
        targetfile="${ANT_FINDBUGSXML}"
      ;;
    esac

    while read -r line; do
      files+=("${line}")
    done < <(find . -name "${targetfile}")

    if [[ "${#files[@]}" -lt 1 ]]; then
      module_status ${i} 0 "" "${name}/${module} no findbugs output file (${targetfile})"
      ((i=i+1))
      continue
    fi

    warnings_file="${PATCH_DIR}/${name}-findbugs-${fn}-warnings"

    "${FINDBUGS_HOME}/bin/unionBugs" -withMessages -output "${warnings_file}.xml" "${files[@]}"

    if [[ ${name} == branch ]]; then
      "${FINDBUGS_HOME}/bin/setBugDatabaseInfo" -name "${PATCH_BRANCH}" \
          "${warnings_file}.xml" "${warnings_file}.xml"
      retval=$?
    else
      "${FINDBUGS_HOME}/bin/setBugDatabaseInfo" -name patch \
          "${warnings_file}.xml" "${warnings_file}.xml"
      retval=$?
    fi

    if [[ ${retval} != 0 ]]; then
      savestop=$(stop_clock)
      MODULE_STATUS_TIMER[${i}]=${savestop}
      module_status ${i} -1 "" "${name}/${module} cannot run setBugDatabaseInfo from findbugs"
      ((result=result+1))
      ((i=i+1))
      continue
    fi

    if ! "${FINDBUGS_HOME}/bin/convertXmlToText" -html \
      "${warnings_file}.xml" \
      "${warnings_file}.html"; then
      savestop=$(stop_clock)
      MODULE_STATUS_TIMER[${i}]=${savestop}
      module_status ${i} -1 "" "${name}/${module} cannot run convertXmlToText from findbugs"
      ((result=result+1))
    fi

    if [[ -z ${FINDBUGS_VERSION}
        && ${name} == branch ]]; then
      FINDBUGS_VERSION=$(${GREP} -i "BugCollection version=" "${warnings_file}.xml" \
        | cut -f2 -d\" \
        | cut -f1 -d\" )
      if [[ -n ${FINDBUGS_VERSION} ]]; then
        add_footer_table findbugs "v${FINDBUGS_VERSION}"
      fi
    fi

    ((i=i+1))
  done
  return ${result}
}

## @description  Track pre-existing findbugs warnings
## @audience     private
## @stability    evolving
## @replaceable  no
## @return       0 on success
## @return       1 on failure
function findbugs_preapply
{
  declare fn
  declare module
  declare modindex=0
  declare warnings_file
  declare module_findbugs_warnings
  declare result=0
  declare msg

  if ! verify_needed_test findbugs; then
    return 0
  fi

  big_console_header "findbugs detection: ${PATCH_BRANCH}"

  findbugs_runner branch
  result=$?

  if [[ ${UNSUPPORTED_TEST} = true ]]; then
    return 0
  fi

  until [[ ${modindex} -eq ${#MODULE[@]} ]]; do
    if [[ ${MODULE_STATUS[${modindex}]} == -1 ]]; then
      ((result=result+1))
      ((modindex=modindex+1))
      continue
    fi

    module=${MODULE[${modindex}]}
    start_clock
    offset_clock "${MODULE_STATUS_TIMER[${modindex}]}"
    fn=$(module_file_fragment "${module}")

    if [[ "${module}" == . ]]; then
      module=root
    fi

    warnings_file="${PATCH_DIR}/branch-findbugs-${fn}-warnings"
    # shellcheck disable=SC2016
    module_findbugs_warnings=$("${FINDBUGS_HOME}/bin/filterBugs" -first \
        "${PATCH_BRANCH}" \
        "${warnings_file}.xml" \
        "${warnings_file}.xml" \
        | ${AWK} '{print $1}')

    if [[ ${module_findbugs_warnings} -gt 0 ]] ; then
      msg="${module} in ${PATCH_BRANCH} has ${module_findbugs_warnings} extant Findbugs warnings."
      if [[ "${FINDBUGS_WARNINGS_FAIL_PRECHECK}" = "true" ]]; then
        module_status ${modindex} -1 "branch-findbugs-${fn}-warnings.html" "${msg}"
        ((result=result+1))
      elif [[ "${BUILDMODE}" = full ]]; then
        module_status ${modindex} -1 "branch-findbugs-${fn}-warnings.html" "${msg}"
        ((result=result+1))
        populate_test_table FindBugs "module:${module}"
        #shellcheck disable=SC2162
        while read line; do
          firstpart=$(echo "${line}" | cut -f2 -d:)
          secondpart=$(echo "${line}" | cut -f9- -d' ')
          add_test_table "" "${firstpart}:${secondpart}"
        done < <("${FINDBUGS_HOME}/bin/convertXmlToText" "${warnings_file}.xml")
      else
        module_status ${modindex} 0 "branch-findbugs-${fn}-warnings.html" "${msg}"
      fi
    fi

    savestop=$(stop_clock)
    MODULE_STATUS_TIMER[${modindex}]=${savestop}
    ((modindex=modindex+1))
  done
  modules_messages branch findbugs true

  if [[ ${result} != 0 ]]; then
    return 1
  fi
  return 0
}

## @description  Verify patch does not trigger any findbugs warnings
## @audience     private
## @stability    evolving
## @replaceable  no
## @return       0 on success
## @return       1 on failure
function findbugs_postinstall
{
  declare module
  declare fn
  declare combined_xml
  declare branchxml
  declare patchxml
  declare newbugsbase
  declare fixedbugsbase
  declare branch_warnings
  declare patch_warnings
  declare fixed_warnings
  declare line
  declare firstpart
  declare secondpart
  declare i=0
  declare result=0
  declare savestop
  declare summarize=true
  declare statstring

  if ! verify_needed_test findbugs; then
    return 0
  fi

  big_console_header "findbugs detection: ${BUILDMODE}"

  findbugs_runner patch

  if [[ ${UNSUPPORTED_TEST} = true ]]; then
    return 0
  fi

  until [[ $i -eq ${#MODULE[@]} ]]; do
    if [[ ${MODULE_STATUS[${i}]} == -1 ]]; then
      ((result=result+1))
      ((i=i+1))
      continue
    fi

    start_clock
    offset_clock "${MODULE_STATUS_TIMER[${i}]}"
    module="${MODULE[${i}]}"

    buildtool_cwd "${i}"

    fn=$(module_file_fragment "${module}")

    if [[ "${module}" == . ]]; then
      module=root
    fi

    combined_xml="${PATCH_DIR}/combined-findbugs-${fn}.xml"
    branchxml="${PATCH_DIR}/branch-findbugs-${fn}-warnings.xml"
    patchxml="${PATCH_DIR}/patch-findbugs-${fn}-warnings.xml"

    if [[ -f "${branchxml}" ]]; then
      # shellcheck disable=SC2016
      branch_warnings=$("${FINDBUGS_HOME}/bin/filterBugs" -first \
          "${PATCH_BRANCH}" \
          "${branchxml}" \
          "${branchxml}" \
          | ${AWK} '{print $1}')
    else
      branchxml=${patchxml}
    fi

    newbugsbase="${PATCH_DIR}/new-findbugs-${fn}"
    fixedbugsbase="${PATCH_DIR}/fixed-findbugs-${fn}"

    if ! "${FINDBUGS_HOME}/bin/computeBugHistory" -useAnalysisTimes -withMessages \
            -output "${combined_xml}" \
            "${branchxml}" \
            "${patchxml}"; then
      module_status ${i} -1 "" "${module} cannot run computeBugHistory from findbugs"
      ((result=result+1))
      savestop=$(stop_clock)
      MODULE_STATUS_TIMER[${i}]=${savestop}
      ((i=i+1))
      popd >/dev/null || return 1
      continue
    fi

    # shellcheck disable=SC2016
    patch_warnings=$("${FINDBUGS_HOME}/bin/filterBugs" -first \
        "patch" \
        "${patchxml}" \
        "${patchxml}" \
        | ${AWK} '{print $1}')

    #shellcheck disable=SC2016
    add_warnings=$("${FINDBUGS_HOME}/bin/filterBugs" -first patch \
        "${combined_xml}" "${newbugsbase}.xml" | ${AWK} '{print $1}')
    retval=$?
    if [[ ${retval} != 0 ]]; then
      module_status ${i} -1 "" "${module} cannot run filterBugs (#1) from findbugs"
      ((result=result+1))
      savestop=$(stop_clock)
      MODULE_STATUS_TIMER[${i}]=${savestop}
      ((i=i+1))
      popd >/dev/null || return 1
      continue
    fi

    #shellcheck disable=SC2016
    fixed_warnings=$("${FINDBUGS_HOME}/bin/filterBugs" -fixed patch \
        "${combined_xml}" "${fixedbugsbase}.xml" | ${AWK} '{print $1}')
    retval=$?
    if [[ ${retval} != 0 ]]; then
      module_status ${i} -1 "" "${module} cannot run filterBugs (#2) from findbugs"
      ((result=result+1))
      savestop=$(stop_clock)
      MODULE_STATUS_TIMER[${i}]=${savestop}
      ((i=i+1))
      popd >/dev/null || return 1
      continue
    fi

    statstring=$(generic_calcdiff_status "${branch_warnings}" "${patch_warnings}" "${add_warnings}")

    if ! "${FINDBUGS_HOME}/bin/convertXmlToText" -html "${newbugsbase}.xml" \
        "${newbugsbase}.html"; then
      module_status ${i} -1 "" "${module} cannot run convertXmlToText from findbugs"
      ((result=result+1))
      savestop=$(stop_clock)
      MODULE_STATUS_TIMER[${i}]=${savestop}
      ((i=i+1))
      popd >/dev/null || return 1
      continue
    fi

    if [[ ${add_warnings} -gt 0 ]] ; then
      populate_test_table FindBugs "module:${module}"
      #shellcheck disable=SC2162
      while read line; do
        firstpart=$(echo "${line}" | cut -f2 -d:)
        secondpart=$(echo "${line}" | cut -f9- -d' ')
        add_test_table "" "${firstpart}:${secondpart}"
      done < <("${FINDBUGS_HOME}/bin/convertXmlToText" "${newbugsbase}.xml")

      module_status ${i} -1 "new-findbugs-${fn}.html" "${module} ${statstring}"
      ((result=result+1))
    elif [[ ${fixed_warnings} -gt 0 ]]; then
      module_status ${i} +1 "" "${module} ${statstring}"
      summarize=false
    fi
    savestop=$(stop_clock)
    MODULE_STATUS_TIMER[${i}]=${savestop}
    popd >/dev/null || return 1
    ((i=i+1))
  done

  modules_messages patch findbugs "${summarize}"
  if [[ ${result} != 0 ]]; then
    return 1
  fi
  return 0
}

function findbugs_rebuild
{
  declare repostatus=$1

  if [[ "${repostatus}" = branch || "${BUILDMODE}" = full ]]; then
    findbugs_preapply
  else
    findbugs_postinstall
  fi
}
