// Spray paint colors for "nearest spray paint" matching, one "code|name|hex" per line.
// MTN 94 values are the hex colors Montana Colors publishes for each shade (montanacolors.com);
// screen colors only approximate the paint, so test on a scrap first. Spectral (see-through),
// fluorescent and metallic shades are left out: they don't match a solid specified color.

extension SprayPaints {
    static let mtn94Table = """
RV-189|Ipanema Yellow|FFF9C3
RV-20|Party Yellow|FFEF8C
RV-109|Canarias Yellow|FFF058
RV-1021|Light Yellow|FEDF00
RV-110|Yosemite Yellow|C7B300
RV-111|Babel Green|A29400
RV-112|Mission Green|766A10
RV-113|Dragon Green|5E5003
RV-114|Maya Green|3D3408
RV-192|Sundance|FFEBC2
RV-102|Dalai Orange|FDDCA3
RV-103|Plural Orange|FAC67E
RV-50|Solar Orange|F7B060
RV-105|Tangerine|F5A54A
RV-106|Lava Orange|EF8407
RV-2004|Kalani Orange|EA640D
RV-107|Mars Orange|E64715
RV-108|Phoenix Orange|BE3819
RV-190|Malta White|F9F6E9
RV-1013|Bone White|F3EFD6
RV-135|Safari Brown|EADFA8
RV-136|Inca Brown|D9B365
RV-137|Kraft Brown|BD9B61
RV-139|Sequoia Brown|6F5229
RV-138|Marrakech|99743F
RV-140|Mole Brown|503915
RV-141|Gondola Brown|412C13
RV-191|Jaima Brown|F1E8DE
RV-94|Dingo Brown|E8D0B7
RV-95|Tana Brown|D2A785
RV-96|Montserrat|CC955E
RV-97|Chiapas Brown|A0682B
RV-98|Bean Brown|A65F2F
RV-100|Coffee Brown|402009
RV-35|Chocolate Brown|41302A
RV-101|Ebony Brown|2F1109
RV-193|Chewing Gum|F6C3D3
RV-115|Tutti Frutti|EA949D
RV-3017|Fever Red|DC534D
RV-116|Blood Red|D52F25
RV-3001|Vivid Red|B3061E
RV-47|Clandestine Red|950825
RV-3004|Bordeaux Red|610819
RV-3007|Cherokee Red|3A0807
RV-77|Night Red|2D0604
RV-194|Supernova Pink|FCE6EB
RV-164|Tokyo Pink|F7C7D7
RV-165|Orchid Pink|EC7FAA
RV-4003|Erika|E85B99
RV-4010|Magenta|D90075
RV-166|Açai Red|9A004B
RV-167|Rioja Red|6B0037
RV-168|Anger Red|550026
RV-169|Taurus Red|36001C
RV-196|Saudade Pink|F2DDDD
RV-86|Boreal Pink|E3BFC3
RV-87|Stereo Pink|CA95A4
RV-88|Single Pink|A06C7E
RV-89|Compact Red|864A54
RV-90|Matilde Red|582B3A
RV-91|Pandora Red|4F1F30
RV-92|Gaudi Red|321129
RV-93|Stendhal Red|1E000E
RV-197|Penelope Brown|F8EDE7
RV-176|Sensible Brown|EFD9D0
RV-203|Oak Brown|A86059
RV-204|Interrail Brown|9F3D44
RV-205|Warrior Brown|5A1521
RV-200|Plancton|E8D6C8
RV-64|Respect Pink|B59892
RV-201|Scarlet Brown|8E6061
RV-202|Mosquito Brown|684445
RV-321|April Violet|E9CDE4
RV-195|Shiva Violet|E5CCE1
RV-322|Arlet Violet|D0ADD2
RV-170|Persia Violet|C5ADD0
RV-323|Mandala Violet|BC90C1
RV-276|Bishop Violet|C29BCB
RV-275|Raval Violet|94679C
RV-283|Sultan Violet|83577D
RV-274|Reverend Violet|6C5D80
RV-310|Republic Violet|DACBE5
RV-311|Woodstock Violet|CDC3E1
RV-171|Community Violet|B194C0
RV-172|Destiny Violet|8270A3
RV-173|Ultraviolet|6B4D8D
RV-174|Venus Violet|483366
RV-175|Electra Violet|32234E
RV-28|Cosmos Violet|241C46
RV-27|Vampire Violet|140632
RV-312|Valenti Blue|C1CAE8
RV-313|Martínez Blue|AEBEE3
RV-314|Rosemary Blue|9DB1DC
RV-315|Dancer Blue|85A0D3
RV-316|Marseille Blue|6386C3
RV-317|Porto Blue|616CB1
RV-318|Ween Blue|3B54A1
RV-319|Tuareg Blue|263284
RV-320|Mantra Blue|302B66
RV-184|Rain Blue|C4E7F8
RV-149|Hydra Blue|8ECAE5
RV-150|Argo Blue|44B3DF
RV-151|Freedom Blue|0098D2
RV-152|Europe Blue|0074B0
RV-30|Electric Blue|005891
RV-5005|Dark Blue|003875
RV-154|Twister Blue|042151
RV-5013|Navy Blue|010E30
RV-185|Angel Blue|EAF0F5
RV-156|Barceloneta Blue|CAE4F0
RV-157|Thalassa Blue|A2D3EA
RV-158|Perseus Blue|7FB8D5
RV-159|Odyssey Blue|6EA4BE
RV-160|Eureka Blue|467289
RV-161|Jase Blue|2E4A5B
RV-162|Deep Blue|003447
RV-163|Poseydon Blue|00202C
RV-186|Virgin Green|F5FAF7
RV-142|Gemini Green|E1F0E8
RV-6027|Luminous Green|A1D5CF
RV-144|Bali Green|7BC6C0
RV-145|Erasmus Green|5BB5B5
RV-5018|Turquoise|008691
RV-146|Glory Blue|2D6A75
RV-147|Pegasus Blue|003640
RV-148|Hercules Blue|002628
RV-187|Vespa Green|F1F5DF
RV-124|Frisco Green|D4E19E
RV-16|Pistachio Green|BDD268
RV-125|Neon Green|A5B700
RV-34|Guacamole Green|81A512
RV-6018|Valley Green|4A7518
RV-126|Toscana Green|2B491E
RV-127|Era Green|142F0F
RV-6009|Amazon Green|0F2405
RV-188|Shining Green|F2EDBE
RV-1016|Lemon Yellow|DCD872
RV-129|Oregano Green|AFAB00
RV-60|Krypton Green|83890E
RV-130|Euskadi Green|50590D
RV-131|Comarca Green|333B08
RV-132|Borneo Green|283307
RV-133|Dharma Green|1E2705
RV-134|Infinite Green|131C04
RV-270|Formentera Blue|00B4BC
RV-269|Genesis Blue|179DAB
RV-268|Tramontana Blue|007788
RV-199|Java Green|86C8B4
RV-182|Emerald Green|009E8F
RV-183|Beryl Green|117774
RV-179|Bonsai Green|B8BB86
RV-180|Thai Green|8E966E
RV-181|Labyrinth Green|47492B
RV-267|Sulfur Yellow|FAEB37
RV-266|Psycho Green|D5E739
RV-265|Sonar Green|B9BE56
RV-281|Laser Green|99C221
RV-282|Laos Green|8FCB24
RV-280|Hulk Green|41A248
RV-272|Mint Green|29CB7E
RV-273|Iguana Green|8CC947
RV-271|Mystic Green|25BD59
RV-1017|Peach|E6A65D
R-1028|Medium Yellow|FFA300
RV-207|Mango|E87722
RV-177|Eldorado|F1C700
RV-178|Tibet|D58B26
RV-8023|Mustard|A76225
RV-99|Glace Brown|7A3D24
RV-278|Joker Pink|E44C9A
RV-277|Disco Pink|BD51A2
RV-279|Rosario Pink|DC4588
RV-3020|Light Red|EF3A38
RV-241|Madrid Red|F65058
RV-245|Cyan|00FFFF
RV-243|Babylon Blue|3D5588
RV-198|Stardust Grey|EEF0F1
RV-7047|Siberian Grey|DBDDDF
RV-118|Rita Grey|CDD0D1
R-7040|Pearl Grey|B5B8BA
RV-119|London Grey|898B8E
RV-120|Wolf Grey|5B5B5E
RV-121|Icarus Grey|48484B
RV-7016|Anthracite Grey|363538
RV-78|Metropolis Grey|262227
RV-300|Tofu Grey|FEF9E3
RV-301|Placebo Grey|F5EFD6
RV-302|Koala Grey|D8CDC3
RV-303|Native Grey|BCB2AD
RV-304|Balboa Grey|A29690
RV-305|Cloud Grey|C9D2D7
RV-306|Winter Grey|B7C1CD
RV-307|Jaws Grey|ABB5C1
RV-308|Whale Grey|6B7C91
RV-309|Chernobyl Grey|5E7386
RV-9010|White|FFFFFF
RV-9011|Black|000000
"""
}
