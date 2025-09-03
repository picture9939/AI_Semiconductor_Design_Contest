#User need to set <tool_installation> to user's tool path


echo "Sourcing Xcelium license"
#setenv XLMHOME /grid/avs/install/xcelium/1903/19.03.001
#/grid/avs/install/xcelium/1909/19.09.001
setenv XLMHOME /grid/avs/install/xcelium/2209/22.09.001

echo "Sourcing vManager license to lauch IMC tool"
#setenv VMGRHOME /grid/avs/install/vmanager/2209/22.09.002
setenv VMGRHOME /grid/avs/install/vmanager/2203/22.03.001

echo "Sourcing Modus License"
setenv MODHOME /icd/flow/MODUS/MODUS221/22.10.000

echo "Sourcing Conformal License"
setenv CNFRLHOME /icd/flow/CONFRML/CONFRML222/22.20.100

echo "Sourcing DDI221 Genus License"
setenv DDIGENUS /icd/flow/DDI/DDI221/22.10-p001_1/GENUS221
 
echo "Sourcing DDI221 Innovus License"
setenv DDIINV /icd/flow/DDI/DDI221/22.10-p001_1/INNOVUS221
#setenv DDIINV /icd/flow/DDI/DDI221/22.11-s119_1/INNOVUS221/

echo "Sourcing SSVHOME License"
setenv SSVHOME /icd/flow/SSV/SSV221/22.10-p001_1
#setenv SSVHOME /icd/flow/SSV/SSV221/22.11-s121_1

set path = ( $XLMHOME/tools/bin \
             $VMGRHOME/bin \
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

