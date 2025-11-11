#User need to set <tool_installation> to user's tool path


echo "Sourcing Xcelium license"
setenv XLMHOME /grid/avs/install/xcelium/2309/23.09.001

echo "Sourcing Verisium Debug"
setenv VERISIUM_DEBUG_ROOT /grid/avs/install/verisium_debug/MAIN2309/23.09.001

echo "Sourcing vManager license to lauch IMC tool"
setenv VMGRHOME /grid/avs/install/vmanager/2309/23.09.001

echo "Sourcing Modus License"
setenv MODHOME /icd/flow/MODUS/MODUS231/23.10.000

echo "Sourcing Conformal License"
setenv CNFRLHOME /icd/flow/CONFRML/CONFRML232/23.20.100

echo "Sourcing DDI221 Genus License"
setenv DDIGENUS /icd/flow/DDI/DDI231/23.10-p003_1/GENUS231

echo "Sourcing DDI221 Innovus License"
setenv DDIINV /icd/flow/DDI/DDI231/23.10-p003_1/INNOVUS231

echo "Sourcing SSVHOME License"
setenv SSVHOME /icd/flow/SSV/SSV231/23.10-p001_1


set path = ( $XLMHOME/tools/bin \
             $VMGRHOME/tools/bin \
             $VERISIUM_DEBUG_ROOT/tools/bin \
             $MODHOME/lnx86/tools.lnx86/bin   \
             $CNFRLHOME/lnx86/tools.lnx86/bin \
	     $DDIGENUS/tools.lnx86/bin \
	     $DDIINV/tools.lnx86/bin \
	     $SSVHOME/lnx86/tools.lnx86/bin \
             $path )

foreach t ( xrun imc modus genus lec innovus tempus) 
   echo "Found $t at `which $t`"
end

#

