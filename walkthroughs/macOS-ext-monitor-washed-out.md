The color on some monitors appear washed out when connected to macOS.

The reason for this is macOS sometimes chooses to use YCrCb signal instead of the full-range RGB.

The steps below are for macOS 26+. They are a little different for macOS <26.

Start with finding the EDID, VendorID, and ProductID of your monitor:
```
ioreg -l | grep -v "EventLog" | grep -5 "EDID"
```

If you have multiple external monitors connected, make sure to find the right one based on the ProductName (which is the name displayed in System Settings > Displays) and ManufacturerName.

The EDID is a long hexadecimal string, such as this:
> 00ffffffffffff0006b3...

The VendorID is in the EDID. Take characters at positions 15-20 (inclusive), in the sample above:
> 0006b3

Strip the leading zeros and it becomes, this is the VendorID in hexadecimal:
> 6b3

The ProductID is an integer, for example:
> 1  \
> 4076  \
> 13345

Save the full EDID string in a file:
> edid-[VendorName]-[ProductName].txt

Convert the hexadecimal EDID to binary:
```
cat edid-[VendorName]-[ProductName].txt | xxd -r -p > edid-[VendorName]-[ProductName].bin
```

Download and install AW EDID Editor: https://www.analogway.com/americas/products/software-tools/aw-edid-editor/

[Screenshot here]

Disable all YCbCr profiles:

[Screenshot 1]

[Screenshot 2]

[Screenshot 3]

...

[Screenshot N]

Save As...
> edid-[VendorName]-[ProductName]_rgb-only.bin

**(Optional)** Convert the modified binary EDID back to hexadecimal, if you want to review the content:
```
xxd -ps edid-[VendorName]-[ProductName]_rgb-only.bin > edid-[VendorName]-[ProductName]_rgb-only.txt
```

Convert the binary EDID to base64:
```
cat edid-[VendorName]-[ProductName]_rgb-only.bin | base64
```

Copy the output and place it as the <data> tag value:
```
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>DisplayProductID</key>
	<integer>[ProductID-as-int]</integer>
	<key>DisplayProductName</key>
	<string>[VendorName] [ProductName]</string>
	<key>DisplayVendorID</key>
	<integer>[VendorID-as-int]</integer>
	<key>IODisplayEDID</key>
	<data>[base64-edid-here]</data>
</dict>
</plist>
```

Save this XML / plist file as:
> DisplayProductID-[ProductID-as-hex]

Finally, move this file into the following directory:
> /Library/Displays/Contents/Resources/Overrides/DisplayVendorID-[VendorID-as-hex]/
(create the directories if they don't exist)

Restart