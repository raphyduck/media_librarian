# frozen_string_literal: true

class Languages
  ISO_639_2 = {
    'nor' => 'no', 'nob' => 'no', 'nno' => 'no', 'nb' => 'no', 'nn' => 'no',
    'heb' => 'he', 'aar' => 'aa', 'abk' => 'ab', 'afr' => 'af', 'aka' => 'ak',
    'alb' => 'sq', 'sqi' => 'sq', 'amh' => 'am', 'ara' => 'ar', 'arm' => 'hy', 'hye' => 'hy',
    'ava' => 'av', 'ave' => 'ae', 'aym' => 'ay', 'aze' => 'az', 'bak' => 'ba', 'bam' => 'bm',
    'ben' => 'bn', 'bis' => 'bi', 'bos' => 'bs', 'bre' => 'br', 'bul' => 'bg', 'cat' => 'ca',
    'cha' => 'ch', 'chv' => 'cv', 'cor' => 'kw', 'cos' => 'co', 'cre' => 'cr',
    'cze' => 'cs', 'ces' => 'cs', 'dan' => 'da', 'div' => 'dv', 'dzo' => 'dz', 'epo' => 'eo',
    'est' => 'et', 'ewe' => 'ee', 'fao' => 'fo', 'fij' => 'fj', 'fin' => 'fi', 'fry' => 'fy',
    'ful' => 'ff', 'geo' => 'ka', 'kat' => 'ka', 'gla' => 'gd', 'gle' => 'ga', 'glg' => 'gl',
    'glv' => 'gv', 'gre' => 'el', 'ell' => 'el', 'grn' => 'gn', 'guj' => 'gu', 'hat' => 'ht',
    'hau' => 'ha', 'her' => 'hz', 'hin' => 'hi', 'hrv' => 'hr', 'hun' => 'hu', 'ibo' => 'ig',
    'ice' => 'is', 'isl' => 'is', 'ido' => 'io', 'iku' => 'iu', 'ind' => 'id', 'ipk' => 'ik',
    'jav' => 'jv', 'kal' => 'kl', 'kan' => 'kn', 'kas' => 'ks', 'kau' => 'kr', 'kaz' => 'kk',
    'kik' => 'ki', 'kin' => 'rw', 'kir' => 'ky', 'kom' => 'kv', 'kon' => 'kg', 'kua' => 'kj',
    'kur' => 'ku', 'lat' => 'la', 'lav' => 'lv', 'lim' => 'li', 'lin' => 'ln', 'lit' => 'lt',
    'ltz' => 'lb', 'lug' => 'lg', 'mac' => 'mk', 'mkd' => 'mk', 'mah' => 'mh', 'mal' => 'ml',
    'mao' => 'mi', 'mri' => 'mi', 'mar' => 'mr', 'may' => 'ms', 'msa' => 'ms', 'mlg' => 'mg',
    'mlt' => 'mt', 'mon' => 'mn', 'nau' => 'na', 'nav' => 'nv', 'ndo' => 'ng', 'nep' => 'ne',
    'nya' => 'ny', 'oji' => 'oj', 'ori' => 'or', 'orm' => 'om', 'oss' => 'os', 'pan' => 'pa',
    'per' => 'fa', 'fas' => 'fa', 'pli' => 'pi', 'pol' => 'pl', 'pus' => 'ps', 'que' => 'qu',
    'roh' => 'rm', 'rum' => 'ro', 'ron' => 'ro', 'run' => 'rn', 'sag' => 'sg', 'san' => 'sa',
    'sin' => 'si', 'slo' => 'sk', 'slk' => 'sk', 'slv' => 'sl', 'smo' => 'sm', 'sna' => 'sn',
    'snd' => 'sd', 'som' => 'so', 'sot' => 'st', 'srd' => 'sc', 'srp' => 'sr', 'ssw' => 'ss',
    'sun' => 'su', 'swa' => 'sw', 'tah' => 'ty', 'tam' => 'ta', 'tat' => 'tt', 'tel' => 'te',
    'tgk' => 'tg', 'tgl' => 'tl', 'fil' => 'tl', 'tha' => 'th', 'tib' => 'bo', 'bod' => 'bo',
    'tir' => 'ti', 'tsn' => 'tn', 'tso' => 'ts', 'tuk' => 'tk', 'tur' => 'tr', 'twi' => 'tw',
    'uig' => 'ug', 'ukr' => 'uk', 'urd' => 'ur', 'uzb' => 'uz', 'ven' => 've', 'vie' => 'vi',
    'vol' => 'vo', 'wel' => 'cy', 'cym' => 'cy', 'wln' => 'wa', 'wol' => 'wo', 'xho' => 'xh',
    'yid' => 'yi', 'yor' => 'yo', 'zha' => 'za', 'zul' => 'zu'
  }.freeze

  def self.get_code(from_language)
    code = from_language.to_s.downcase
    return nil if code.empty?
    match = LANG_ADJUST.find { |_, langs| langs.include?(code) } ||
            LANG_ADJUST.find { |_, langs| langs.include?(ISO_639_2[code]) }
    match && match[0].to_s
  end

  def self.sort_languages(preferred_langs)
    llist = LANG_ADJUST.dup
    (preferred_langs.to_s.split(' ').map { |l| llist.delete(l.to_sym) } + llist.map { |_, ls| ls }).flatten
  end
end
