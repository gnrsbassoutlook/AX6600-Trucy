import subprocess, sys

MULTI = """sda|disk|sda|7814037168|||||ATA      ST4000VX005-2LY1
sdb|disk|sdb|3907029168|||||ATA      WDC WD20EFRX-68E
sdc|disk|sdc|1953525168|||||ATA      ST1000DM003-1CH1
sdd|disk|sdd|15628053168|exfat||||/mnt/sdd|
sda1|part|sda|32768|||||
sda2|part|sda|7814000640|ntfs||8CB8C15FB8C14902|/mnt/sda2|
sdb1|part|sdb|3907029135|ext4||3f2a1b0c-1111-2222-3333-444455556666||
sdc1|part|sdc|1953525135|ntfs||A1B2C3D4E5F60718|/mnt/sdc1|
mmcblk0p27|ipart|mmcblk0|233920480|ext4||ec444341-4596-4d00-b0c9-36ca8ca223e4||SLD128
"""

RAID5 = """sda|disk|sda|7814037168|||||ATA      ST4000VX005-2LY1
sdb|disk|sdb|23438057472|||||RAID5_VOLUME
sda1|part|sda|32768|||||
sda2|part|sda|7814000640|ntfs||8CB8C15FB8C14902|/mnt/sda2|
sdb1|part|sdb|23438057439|ext4||99887766-5544-3322-1100-aabbccddeeff|/mnt/sdb1|
mmcblk0p27|ipart|mmcblk0|233920480|ext4||ec444341-4596-4d00-b0c9-36ca8ca223e4||SLD128
"""

case = sys.argv[1]
open('/tmp/oa-sim/fake.devs','w').write(MULTI if case=='multi' else RAID5)
